//! Typed decision forms: a flat MCP `requestedSchema` or an `AskUserQuestion` payload becomes a
//! [`DecisionForm`], and answers are validated against it without coercion.
//!
//! Port of `NativeLab`'s `DecisionForm.swift`, extended to every MCP 2025-11-25 form schema:
//! titled and untitled single and multi-select enums, `format`, and `default`. Anything the native
//! form cannot express exactly (nested objects, `pattern`, unions, malformed constraints) is a
//! [`FormError`]: it never turns into a less restrictive form or a binary approval.

use std::collections::{BTreeMap, BTreeSet};
use std::fmt;

use omnigent_protocol::ElicitationValue;
use serde_json::{Map, Number, Value};

use super::text_format::TextFormat;

/// Most fields (schema properties or questions) one native form renders.
pub const MAX_FORM_FIELDS: usize = 32;
/// Most options one field offers.
pub const MAX_FIELD_OPTIONS: usize = 100;

const SCHEMA_KEYS: [&str; 7] = [
    "type",
    "properties",
    "required",
    "title",
    "description",
    "$schema",
    "additionalProperties",
];
const PROPERTY_KEYS: [&str; 16] = [
    "type",
    "title",
    "description",
    "enum",
    "enumNames",
    "oneOf",
    "format",
    "default",
    "minimum",
    "maximum",
    "minLength",
    "maxLength",
    "minItems",
    "maxItems",
    "items",
    "uniqueItems",
];
const ITEMS_KEYS: [&str; 5] = ["type", "enum", "enumNames", "anyOf", "oneOf"];
/// Keys of one titled option (`{"const": "a", "title": "A"}`).
const CONST_OPTION_KEYS: [&str; 3] = ["const", "title", "description"];

/// One choice a field offers.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FormOption {
    /// The value posted when chosen.
    pub value: String,
    /// What to show; the value unless the schema named it.
    pub label: String,
    /// Extra description (a question option's `description`).
    pub detail: String,
    /// What choosing it would look like (a question option's `preview`: a mockup, code or a
    /// diagram, shown as written); empty when none.
    pub preview: String,
}

impl FormOption {
    fn plain(value: String) -> Self {
        Self {
            label: value.clone(),
            value,
            detail: String::new(),
            preview: String::new(),
        }
    }
}

/// The native control a field needs, and the answer type it takes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum FieldKind {
    /// Free text: [`ElicitationValue::Text`].
    Text,
    /// Any finite number: [`ElicitationValue::Integer`] or [`ElicitationValue::Number`].
    Number,
    /// A whole number: [`ElicitationValue::Integer`] only.
    Integer,
    /// [`ElicitationValue::Bool`].
    Boolean,
    /// One option (or a custom answer when allowed): [`ElicitationValue::Text`].
    SingleChoice,
    /// Several options: [`ElicitationValue::TextList`].
    MultipleChoice,
}

/// One field of a [`DecisionForm`].
#[derive(Debug, Clone, PartialEq)]
#[allow(
    clippy::struct_excessive_bools,
    reason = "independent per-field flags, mirrored from the schema or question"
)]
pub struct FormField {
    /// The `content` key the answer is posted under.
    pub key: String,
    /// What to show as the field's label.
    pub title: String,
    /// Description or question header.
    pub detail: String,
    /// The control and answer type.
    pub kind: FieldKind,
    /// An answer is required.
    pub required: bool,
    /// Offered choices (choice kinds only).
    pub options: Vec<FormOption>,
    /// A typed answer outside `options` is allowed (`AskUserQuestion` only).
    pub allows_custom: bool,
    /// The answer should be masked while typed.
    pub is_secret: bool,
    /// The user may add a note to the answer (a question with `acceptsNotes`), sent with
    /// [`DecisionResponse::FormWithNotes`](super::DecisionResponse::FormWithNotes).
    pub accepts_notes: bool,
    /// Inclusive lower bound (number kinds).
    pub minimum: Option<f64>,
    /// Inclusive upper bound (number kinds).
    pub maximum: Option<f64>,
    /// Fewest characters (Unicode scalar values).
    pub min_length: Option<usize>,
    /// Most characters (Unicode scalar values).
    pub max_length: Option<usize>,
    /// Fewest choices (multiple choice).
    pub min_items: Option<usize>,
    /// Most choices (multiple choice).
    pub max_items: Option<usize>,
    /// The format a text answer must match.
    pub format: Option<TextFormat>,
    /// The answer to start with (the schema's `default`, or a question's prefilled text). Only
    /// kept when it is itself a valid answer.
    pub default_value: Option<ElicitationValue>,
}

impl FormField {
    /// A required field of `kind` with no options or constraints.
    #[must_use]
    pub fn new(key: impl Into<String>, title: impl Into<String>, kind: FieldKind) -> Self {
        Self {
            key: key.into(),
            title: title.into(),
            detail: String::new(),
            kind,
            required: true,
            options: Vec::new(),
            allows_custom: false,
            is_secret: false,
            accepts_notes: false,
            minimum: None,
            maximum: None,
            min_length: None,
            max_length: None,
            min_items: None,
            max_items: None,
            format: None,
            default_value: None,
        }
    }

    fn offers(&self, value: &str) -> bool {
        self.options.iter().any(|option| option.value == value)
    }

    /// Checks one answer. `None` and [`ElicitationValue::Null`] mean "not answered".
    ///
    /// # Errors
    ///
    /// The first rule the answer breaks.
    pub fn validate(&self, value: Option<&ElicitationValue>) -> Result<(), AnswerError> {
        let field = || self.title.clone();
        let value = match value {
            None | Some(ElicitationValue::Null) if self.required => {
                return Err(AnswerError::Missing { field: field() });
            }
            None | Some(ElicitationValue::Null) => return Ok(()),
            Some(value) => value,
        };
        match (self.kind, value) {
            (FieldKind::Text | FieldKind::SingleChoice, ElicitationValue::Text(text)) => {
                self.validate_text(text)
            }
            (FieldKind::Number, ElicitationValue::Number(number)) => self.validate_number(*number),
            (FieldKind::Number | FieldKind::Integer, ElicitationValue::Integer(integer)) => {
                Number::from(*integer)
                    .as_f64()
                    .ok_or_else(|| AnswerError::NotANumber { field: field() })
                    .and_then(|number| self.validate_number(number))
            }
            (FieldKind::Integer, ElicitationValue::Number(_)) => {
                Err(AnswerError::NotAWholeNumber { field: field() })
            }
            (FieldKind::Boolean, ElicitationValue::Bool(_)) => Ok(()),
            (FieldKind::MultipleChoice, ElicitationValue::TextList(values)) => {
                self.validate_choices(values)
            }
            _ => Err(AnswerError::WrongType { field: field() }),
        }
    }

    fn validate_text(&self, text: &str) -> Result<(), AnswerError> {
        let field = || self.title.clone();
        if self.required && text.trim().is_empty() {
            return Err(AnswerError::Missing { field: field() });
        }
        let length = text.chars().count();
        if let Some(min) = self.min_length.filter(|min| length < *min) {
            return Err(AnswerError::TooShort {
                field: field(),
                min,
            });
        }
        if let Some(max) = self.max_length.filter(|max| length > *max) {
            return Err(AnswerError::TooLong {
                field: field(),
                max,
            });
        }
        if self.kind == FieldKind::SingleChoice && !self.allows_custom && !self.offers(text) {
            return Err(AnswerError::NotAnOption { field: field() });
        }
        if let Some(format) = self.format.filter(|format| !format.matches(text)) {
            return Err(AnswerError::WrongFormat {
                field: field(),
                format,
            });
        }
        Ok(())
    }

    fn validate_number(&self, number: f64) -> Result<(), AnswerError> {
        let field = || self.title.clone();
        if !number.is_finite() {
            return Err(AnswerError::NotANumber { field: field() });
        }
        if let Some(min) = self.minimum.filter(|min| number < *min) {
            return Err(AnswerError::BelowMinimum {
                field: field(),
                min,
            });
        }
        if let Some(max) = self.maximum.filter(|max| number > *max) {
            return Err(AnswerError::AboveMaximum {
                field: field(),
                max,
            });
        }
        Ok(())
    }

    fn validate_choices(&self, values: &[String]) -> Result<(), AnswerError> {
        let field = || self.title.clone();
        let fewest = self.min_items.unwrap_or_else(|| usize::from(self.required));
        if values.len() < fewest {
            return Err(AnswerError::TooFewChoices { field: field() });
        }
        if let Some(max) = self.max_items.filter(|max| values.len() > *max) {
            return Err(AnswerError::TooManyChoices {
                field: field(),
                max,
            });
        }
        let distinct: BTreeSet<&str> = values.iter().map(String::as_str).collect();
        if distinct.len() != values.len() || values.iter().any(|value| value.trim().is_empty()) {
            return Err(AnswerError::DuplicateOrEmptyChoices { field: field() });
        }
        if !self.allows_custom && !values.iter().all(|value| self.offers(value)) {
            return Err(AnswerError::ChoicesNotOffered { field: field() });
        }
        Ok(())
    }
}

/// Why an answer set does not satisfy a form. The display text is user-facing.
#[derive(Debug, Clone, PartialEq, thiserror::Error)]
pub enum AnswerError {
    /// A key the form does not have.
    #[error("This response contains an unknown field.")]
    UnknownField {
        /// The key as given.
        key: String,
    },
    /// A required field has no answer.
    #[error("Answer {field}.")]
    Missing {
        /// The field title.
        field: String,
    },
    /// Shorter than `minLength`.
    #[error("{field} needs at least {min} characters.")]
    TooShort {
        /// The field title.
        field: String,
        /// The minimum.
        min: usize,
    },
    /// Longer than `maxLength`.
    #[error("{field} allows at most {max} characters.")]
    TooLong {
        /// The field title.
        field: String,
        /// The maximum.
        max: usize,
    },
    /// A single choice outside the offered options.
    #[error("Choose an available answer for {field}.")]
    NotAnOption {
        /// The field title.
        field: String,
    },
    /// Not a finite number.
    #[error("Enter a valid number for {field}.")]
    NotANumber {
        /// The field title.
        field: String,
    },
    /// A non-integer value for an integer field (including `2.0`: no coercion).
    #[error("Enter a valid whole number for {field}.")]
    NotAWholeNumber {
        /// The field title.
        field: String,
    },
    /// Below `minimum`.
    #[error("{field} must be at least {min}.")]
    BelowMinimum {
        /// The field title.
        field: String,
        /// The minimum.
        min: f64,
    },
    /// Above `maximum`.
    #[error("{field} must be at most {max}.")]
    AboveMaximum {
        /// The field title.
        field: String,
        /// The maximum.
        max: f64,
    },
    /// Fewer choices than `minItems` (or none for a required field).
    #[error("Choose an answer for {field}.")]
    TooFewChoices {
        /// The field title.
        field: String,
    },
    /// More choices than `maxItems`.
    #[error("Choose at most {max} answers for {field}.")]
    TooManyChoices {
        /// The field title.
        field: String,
        /// The maximum.
        max: usize,
    },
    /// Repeated or blank choices.
    #[error("Choose distinct, nonempty answers for {field}.")]
    DuplicateOrEmptyChoices {
        /// The field title.
        field: String,
    },
    /// Choices outside the offered options.
    #[error("Choose available answers for {field}.")]
    ChoicesNotOffered {
        /// The field title.
        field: String,
    },
    /// The answer has the wrong JSON type (for example the string `"2"` for a number).
    #[error("Enter a valid answer for {field}.")]
    WrongType {
        /// The field title.
        field: String,
    },
    /// Text that is not in the field's `format`.
    #[error("Enter {} for {field}.", format.expected())]
    WrongFormat {
        /// The field title.
        field: String,
        /// The format it must match.
        format: TextFormat,
    },
}

/// The first problem with an answer set, and the field it is about.
#[derive(Debug, Clone, PartialEq)]
pub struct FormProblem {
    /// The key of the field the problem is about; `None` when it concerns no form field (an
    /// unknown key).
    pub field_key: Option<String>,
    /// What is wrong.
    pub error: AnswerError,
}

/// A native form: fields in display order.
#[derive(Debug, Clone, PartialEq)]
pub struct DecisionForm {
    /// The fields. Keys are unique.
    pub fields: Vec<FormField>,
}

impl DecisionForm {
    /// Checks a whole answer set: no unknown keys, then each field in order.
    ///
    /// # Errors
    ///
    /// The first problem found.
    pub fn validate(&self, values: &BTreeMap<String, ElicitationValue>) -> Result<(), AnswerError> {
        self.problem(values)
            .map_or(Ok(()), |problem| Err(problem.error))
    }

    /// The first problem with an answer set, with the key of the field it is about, so the UI
    /// can show it next to that field. `None` when the answers are valid.
    #[must_use]
    pub fn problem(&self, values: &BTreeMap<String, ElicitationValue>) -> Option<FormProblem> {
        if let Some(key) = values
            .keys()
            .find(|key| !self.fields.iter().any(|field| &field.key == *key))
        {
            return Some(FormProblem {
                field_key: None,
                error: AnswerError::UnknownField { key: key.clone() },
            });
        }
        self.fields.iter().find_map(|field| {
            field
                .validate(values.get(&field.key))
                .err()
                .map(|error| FormProblem {
                    field_key: Some(field.key.clone()),
                    error,
                })
        })
    }

    /// Parses a flat MCP `requestedSchema` object.
    ///
    /// # Errors
    ///
    /// [`FormError`] for any shape or constraint the native form cannot express exactly.
    pub fn from_schema(schema: &Map<String, Value>) -> Result<Self, FormError> {
        if let Some(keyword) = schema
            .keys()
            .find(|key| !SCHEMA_KEYS.contains(&key.as_str()))
        {
            return Err(FormError::UnsupportedSchemaKeyword {
                keyword: keyword.clone(),
            });
        }
        if schema
            .get("type")
            .is_some_and(|kind| kind.as_str() != Some("object"))
        {
            return Err(FormError::NotAnObjectSchema);
        }
        let properties = schema
            .get("properties")
            .and_then(Value::as_object)
            .ok_or(FormError::NotAnObjectSchema)?;
        if properties.is_empty() {
            return Err(FormError::NoFields);
        }
        if properties.len() > MAX_FORM_FIELDS {
            return Err(FormError::TooManyFields {
                count: properties.len(),
            });
        }
        if schema
            .get("additionalProperties")
            .is_some_and(|value| !value.is_boolean())
        {
            return Err(FormError::MalformedSchemaKeyword {
                keyword: "additionalProperties".to_owned(),
            });
        }
        let required = required_keys(schema)?;
        if let Some(missing) = required.iter().find(|key| !properties.contains_key(*key)) {
            return Err(FormError::RequiredFieldMissing {
                field: missing.clone(),
            });
        }
        // `serde_json::Map` is ordered by key without `preserve_order`; sort explicitly anyway.
        let mut keys: Vec<&String> = properties.keys().collect();
        keys.sort();
        let fields = keys
            .into_iter()
            .map(|key| {
                let property = properties
                    .get(key)
                    .and_then(Value::as_object)
                    .ok_or_else(|| FormError::UnsupportedType {
                        field: key.clone(),
                        type_name: "non-object property".to_owned(),
                    })?;
                parse_property(key, property, required.contains(key))
            })
            .collect::<Result<Vec<_>, _>>()?;
        Ok(Self { fields })
    }

    /// Parses an `AskUserQuestion` payload (`{"questions": [...]}`), which Claude, Codex
    /// (`requestUserInput`) and Pi questions share. Every question is required; see
    /// `parse_question` for which take a custom or free-text answer.
    ///
    /// # Errors
    ///
    /// [`FormError`] for a payload without questions, a question without text, a question
    /// without options that does not take free text, or duplicate options or keys.
    pub fn from_questions(payload: &Value) -> Result<Self, FormError> {
        let questions = payload
            .get("questions")
            .and_then(Value::as_array)
            .filter(|questions| !questions.is_empty())
            .ok_or(FormError::NoFields)?;
        if questions.len() > MAX_FORM_FIELDS {
            return Err(FormError::TooManyFields {
                count: questions.len(),
            });
        }
        let fields = questions
            .iter()
            .enumerate()
            .map(|(index, question)| parse_question(index, question))
            .collect::<Result<Vec<_>, _>>()?;
        let keys: BTreeSet<&str> = fields.iter().map(|field| field.key.as_str()).collect();
        if keys.len() != fields.len() {
            return Err(FormError::DuplicateFieldKey);
        }
        Ok(Self { fields })
    }
}

/// Why a schema or question payload cannot become a native form.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum FormError {
    /// Not an object schema with a `properties` object.
    #[error("the schema is not a flat object schema")]
    NotAnObjectSchema,
    /// No properties or questions.
    #[error("the form has no fields")]
    NoFields,
    /// More than [`MAX_FORM_FIELDS`].
    #[error("the form has {count} fields, over the {MAX_FORM_FIELDS}-field limit")]
    TooManyFields {
        /// Fields offered.
        count: usize,
    },
    /// A top-level schema keyword the form cannot honour (for example `oneOf`).
    #[error("the schema uses the unsupported keyword {keyword:?}")]
    UnsupportedSchemaKeyword {
        /// The keyword.
        keyword: String,
    },
    /// A top-level keyword with the wrong JSON type.
    #[error("the schema keyword {keyword:?} is malformed")]
    MalformedSchemaKeyword {
        /// The keyword.
        keyword: String,
    },
    /// `required` names a field that does not exist.
    #[error("the schema requires the undefined field {field:?}")]
    RequiredFieldMissing {
        /// The field key.
        field: String,
    },
    /// A property keyword the form cannot honour (for example `pattern`).
    #[error("field {field:?} uses the unsupported keyword {keyword:?}")]
    UnsupportedKeyword {
        /// The field key.
        field: String,
        /// The keyword.
        keyword: String,
    },
    /// A constraint with a bad value, or a minimum above its maximum.
    #[error("field {field:?} has a malformed {keyword:?} constraint")]
    MalformedConstraint {
        /// The field key.
        field: String,
        /// The keyword.
        keyword: String,
    },
    /// A constraint that does not apply to the field's type.
    #[error("field {field:?} uses {keyword:?}, which does not apply to its type")]
    ConstraintNotApplicable {
        /// The field key.
        field: String,
        /// The keyword.
        keyword: String,
    },
    /// A type the native form has no control for (for example a nested object).
    #[error("field {field:?} has the unsupported type {type_name:?}")]
    UnsupportedType {
        /// The field key.
        field: String,
        /// The type as sent.
        type_name: String,
    },
    /// Empty, oversized, non-string or duplicate options.
    #[error("field {field:?} has malformed options")]
    MalformedOptions {
        /// The field key or question text.
        field: String,
    },
    /// A `format` other than `email`, `uri`, `date` and `date-time`.
    #[error("field {field:?} needs the format {format:?}, which the app cannot check")]
    UnsupportedFormat {
        /// The field key.
        field: String,
        /// The format as sent.
        format: String,
    },
    /// A question without text, or that is not an object.
    #[error("question {index} is malformed")]
    MalformedQuestion {
        /// Zero-based question index.
        index: usize,
    },
    /// Two questions share a key.
    #[error("two questions share a key")]
    DuplicateFieldKey,
    /// `content_preview` names an `AskUserQuestion` call whose arguments are not valid JSON.
    #[error("the question preview is not valid JSON: {message}")]
    MalformedPreview {
        /// Decoder detail.
        message: String,
    },
}

fn required_keys(schema: &Map<String, Value>) -> Result<BTreeSet<String>, FormError> {
    let malformed = || FormError::MalformedSchemaKeyword {
        keyword: "required".to_owned(),
    };
    match schema.get("required") {
        None => Ok(BTreeSet::new()),
        Some(Value::Array(values)) => values
            .iter()
            .map(|value| value.as_str().map(str::to_owned).ok_or_else(malformed))
            .collect(),
        Some(_) => Err(malformed()),
    }
}

/// A finite JSON number, or `None` when absent; an error for any other value.
fn bound(
    field: &str,
    property: &Map<String, Value>,
    keyword: &str,
) -> Result<Option<f64>, FormError> {
    property
        .get(keyword)
        .map(|value| {
            value
                .as_f64()
                .filter(|number| value.is_number() && number.is_finite())
                .ok_or_else(|| FormError::MalformedConstraint {
                    field: field.to_owned(),
                    keyword: keyword.to_owned(),
                })
        })
        .transpose()
}

/// A non-negative JSON integer, or `None` when absent; an error for any other value.
fn count(
    field: &str,
    property: &Map<String, Value>,
    keyword: &str,
) -> Result<Option<usize>, FormError> {
    property
        .get(keyword)
        .map(|value| {
            value
                .as_u64()
                .and_then(|count| usize::try_from(count).ok())
                .ok_or_else(|| FormError::MalformedConstraint {
                    field: field.to_owned(),
                    keyword: keyword.to_owned(),
                })
        })
        .transpose()
}

fn ordered<T: PartialOrd>(
    field: &str,
    keyword: &str,
    lower: Option<T>,
    upper: Option<T>,
) -> Result<(), FormError> {
    match (lower, upper) {
        (Some(lower), Some(upper)) if lower > upper => Err(FormError::MalformedConstraint {
            field: field.to_owned(),
            keyword: keyword.to_owned(),
        }),
        _ => Ok(()),
    }
}

fn string_options(field: &str, values: Option<&Value>) -> Result<Vec<String>, FormError> {
    let malformed = || FormError::MalformedOptions {
        field: field.to_owned(),
    };
    let values = values
        .and_then(Value::as_array)
        .filter(|values| !values.is_empty() && values.len() <= MAX_FIELD_OPTIONS)
        .ok_or_else(malformed)?;
    let options: Vec<String> = values
        .iter()
        .map(|value| value.as_str().map(str::to_owned).ok_or_else(malformed))
        .collect::<Result<_, _>>()?;
    let distinct: BTreeSet<&str> = options.iter().map(String::as_str).collect();
    if distinct.len() != options.len() {
        return Err(malformed());
    }
    Ok(options)
}

fn enum_labels(property: &Map<String, Value>) -> Vec<Option<String>> {
    property
        .get("enumNames")
        .and_then(Value::as_array)
        .map(|labels| {
            labels
                .iter()
                .map(|label| label.as_str().map(str::to_owned))
                .collect()
        })
        .unwrap_or_default()
}

/// `enum` values, labelled by `enumNames` where it names them.
fn labelled_options(key: &str, schema: &Map<String, Value>) -> Result<Vec<FormOption>, FormError> {
    let labels = enum_labels(schema);
    Ok(string_options(key, schema.get("enum"))?
        .into_iter()
        .enumerate()
        .map(
            |(index, value)| match labels.get(index).cloned().flatten() {
                Some(label) => FormOption {
                    label,
                    value,
                    detail: String::new(),
                    preview: String::new(),
                },
                None => FormOption::plain(value),
            },
        )
        .collect())
}

/// Titled options under `keyword` (`oneOf` or `anyOf`): `[{"const": "a", "title": "A"}, ...]`.
/// Entries of any other shape make the keyword a union the form cannot express.
fn const_options(
    key: &str,
    keyword: &str,
    values: Option<&Value>,
) -> Result<Vec<FormOption>, FormError> {
    let malformed = || FormError::MalformedOptions {
        field: key.to_owned(),
    };
    let union = || FormError::UnsupportedKeyword {
        field: key.to_owned(),
        keyword: keyword.to_owned(),
    };
    let entries = values
        .and_then(Value::as_array)
        .filter(|entries| !entries.is_empty() && entries.len() <= MAX_FIELD_OPTIONS)
        .ok_or_else(malformed)?;
    let options = entries
        .iter()
        .map(|entry| {
            let entry = entry.as_object().ok_or_else(union)?;
            if entry
                .keys()
                .any(|name| !CONST_OPTION_KEYS.contains(&name.as_str()))
            {
                return Err(union());
            }
            let value = entry
                .get("const")
                .and_then(Value::as_str)
                .ok_or_else(union)?;
            let text = |name: &str| match entry.get(name) {
                None => Ok(None),
                Some(Value::String(text)) => Ok(Some(text.clone())),
                Some(_) => Err(malformed()),
            };
            Ok(FormOption {
                value: value.to_owned(),
                label: text("title")?.unwrap_or_else(|| value.to_owned()),
                detail: text("description")?.unwrap_or_default(),
                preview: String::new(),
            })
        })
        .collect::<Result<Vec<_>, FormError>>()?;
    let distinct: BTreeSet<&str> = options.iter().map(|option| option.value.as_str()).collect();
    if distinct.len() != options.len() {
        return Err(malformed());
    }
    Ok(options)
}

/// A multi-select's options: `items.enum` (labelled by `items.enumNames`), or titled
/// `items.anyOf` / `items.oneOf`, whose items may leave out `type`.
fn array_options(key: &str, property: &Map<String, Value>) -> Result<Vec<FormOption>, FormError> {
    let unsupported = |keyword: &str| FormError::UnsupportedKeyword {
        field: key.to_owned(),
        keyword: keyword.to_owned(),
    };
    let items = property
        .get("items")
        .and_then(Value::as_object)
        .ok_or_else(|| unsupported("items"))?;
    if let Some(keyword) = items
        .keys()
        .find(|keyword| !ITEMS_KEYS.contains(&keyword.as_str()))
    {
        return Err(unsupported(keyword));
    }
    let titled = match (items.get("anyOf"), items.get("oneOf")) {
        (Some(_), Some(_)) => return Err(unsupported("oneOf")),
        (Some(options), None) => Some(("anyOf", options)),
        (None, Some(options)) => Some(("oneOf", options)),
        (None, None) => None,
    };
    let string_items = items
        .get("type")
        .map_or_else(|| titled.is_some(), |kind| kind.as_str() == Some("string"));
    if !string_items {
        return Err(FormError::UnsupportedType {
            field: key.to_owned(),
            type_name: "array of non-strings".to_owned(),
        });
    }
    match titled {
        Some((keyword, _)) if items.contains_key("enum") || items.contains_key("enumNames") => {
            Err(FormError::ConstraintNotApplicable {
                field: key.to_owned(),
                keyword: keyword.to_owned(),
            })
        }
        Some((keyword, options)) => const_options(key, keyword, Some(options)),
        None => labelled_options(key, items),
    }
}

fn property_kind(
    key: &str,
    property: &Map<String, Value>,
) -> Result<(FieldKind, Vec<FormOption>), FormError> {
    let declared = match property.get("type") {
        None if property.contains_key("enum") || property.contains_key("oneOf") => "string",
        None => "",
        Some(Value::String(kind)) => kind.as_str(),
        Some(_) => {
            return Err(FormError::UnsupportedType {
                field: key.to_owned(),
                type_name: "union".to_owned(),
            });
        }
    };
    let (kind, options) = match declared {
        "string" if property.contains_key("enum") && property.contains_key("oneOf") => {
            return Err(FormError::ConstraintNotApplicable {
                field: key.to_owned(),
                keyword: "oneOf".to_owned(),
            });
        }
        "string" if property.contains_key("enum") => {
            (FieldKind::SingleChoice, labelled_options(key, property)?)
        }
        "string" if property.contains_key("oneOf") => (
            FieldKind::SingleChoice,
            const_options(key, "oneOf", property.get("oneOf"))?,
        ),
        "string" => (FieldKind::Text, Vec::new()),
        "boolean" => (FieldKind::Boolean, Vec::new()),
        "number" => (FieldKind::Number, Vec::new()),
        "integer" => (FieldKind::Integer, Vec::new()),
        "array" => (FieldKind::MultipleChoice, array_options(key, property)?),
        other => {
            return Err(FormError::UnsupportedType {
                field: key.to_owned(),
                type_name: other.to_owned(),
            });
        }
    };
    // Unsupported constraints never silently turn into a less restrictive native form.
    if let Some(keyword) = ["enum", "oneOf"]
        .into_iter()
        .find(|keyword| property.contains_key(*keyword) && kind != FieldKind::SingleChoice)
    {
        return Err(FormError::ConstraintNotApplicable {
            field: key.to_owned(),
            keyword: keyword.to_owned(),
        });
    }
    Ok((kind, options))
}

fn check_applicable(
    key: &str,
    property: &Map<String, Value>,
    kind: FieldKind,
) -> Result<(), FormError> {
    let groups: [(&[&str], bool); 4] = [
        (
            &["minimum", "maximum"],
            matches!(kind, FieldKind::Number | FieldKind::Integer),
        ),
        (
            &["minLength", "maxLength"],
            matches!(kind, FieldKind::Text | FieldKind::SingleChoice),
        ),
        (
            &["items", "minItems", "maxItems", "uniqueItems"],
            kind == FieldKind::MultipleChoice,
        ),
        (&["format"], kind == FieldKind::Text),
    ];
    for (keywords, applies) in groups {
        if !applies
            && let Some(keyword) = keywords
                .iter()
                .find(|keyword| property.contains_key(**keyword))
        {
            return Err(FormError::ConstraintNotApplicable {
                field: key.to_owned(),
                keyword: (*keyword).to_owned(),
            });
        }
    }
    if property
        .get("uniqueItems")
        .is_some_and(|unique| !unique.is_boolean())
    {
        return Err(FormError::MalformedConstraint {
            field: key.to_owned(),
            keyword: "uniqueItems".to_owned(),
        });
    }
    Ok(())
}

fn parse_property(
    key: &str,
    property: &Map<String, Value>,
    required: bool,
) -> Result<FormField, FormError> {
    if let Some(keyword) = property
        .keys()
        .find(|keyword| !PROPERTY_KEYS.contains(&keyword.as_str()))
    {
        return Err(FormError::UnsupportedKeyword {
            field: key.to_owned(),
            keyword: keyword.clone(),
        });
    }
    let minimum = bound(key, property, "minimum")?;
    let maximum = bound(key, property, "maximum")?;
    let min_length = count(key, property, "minLength")?;
    let max_length = count(key, property, "maxLength")?;
    let min_items = count(key, property, "minItems")?;
    let max_items = count(key, property, "maxItems")?;
    ordered(key, "minimum", minimum, maximum)?;
    ordered(key, "minLength", min_length, max_length)?;
    ordered(key, "minItems", min_items, max_items)?;
    let (kind, options) = property_kind(key, property)?;
    check_applicable(key, property, kind)?;
    let format = text_format(key, property)?;
    let default_value = schema_default(key, property, kind)?;
    let text = |name: &str| {
        property
            .get(name)
            .and_then(Value::as_str)
            .map(str::to_owned)
    };
    Ok(FormField {
        key: key.to_owned(),
        title: text("title").unwrap_or_else(|| key.to_owned()),
        detail: text("description").unwrap_or_default(),
        kind,
        required,
        options,
        allows_custom: false,
        is_secret: false,
        accepts_notes: false,
        minimum,
        maximum,
        min_length,
        max_length,
        min_items,
        max_items,
        format,
        default_value,
    }
    .without_invalid_default())
}

/// The property's `format`, when the native form can check it.
fn text_format(key: &str, property: &Map<String, Value>) -> Result<Option<TextFormat>, FormError> {
    let Some(value) = property.get("format") else {
        return Ok(None);
    };
    let name = value
        .as_str()
        .ok_or_else(|| FormError::MalformedConstraint {
            field: key.to_owned(),
            keyword: "format".to_owned(),
        })?;
    TextFormat::parse(name)
        .map(Some)
        .ok_or_else(|| FormError::UnsupportedFormat {
            field: key.to_owned(),
            format: name.to_owned(),
        })
}

/// A JSON number that is whole and within `i64`, as one: `3` and `3.0` alike.
#[allow(
    clippy::as_conversions,
    clippy::cast_possible_truncation,
    reason = "the value is checked to be whole and within i64 before the cast"
)]
fn whole_number(number: &Number) -> Option<i64> {
    const I64_BOUND: f64 = 9_223_372_036_854_775_808.0;
    number.as_i64().or_else(|| {
        number
            .as_f64()
            .filter(|value| value.fract() == 0.0 && (-I64_BOUND..I64_BOUND).contains(value))
            .map(|value| value as i64)
    })
}

/// The property's `default` as an answer. A default of the wrong JSON type is malformed.
fn schema_default(
    key: &str,
    property: &Map<String, Value>,
    kind: FieldKind,
) -> Result<Option<ElicitationValue>, FormError> {
    let Some(value) = property.get("default") else {
        return Ok(None);
    };
    let malformed = || FormError::MalformedConstraint {
        field: key.to_owned(),
        keyword: "default".to_owned(),
    };
    let answer = match (kind, value) {
        (FieldKind::Text | FieldKind::SingleChoice, Value::String(text)) => {
            ElicitationValue::Text(text.clone())
        }
        (FieldKind::Boolean, Value::Bool(flag)) => ElicitationValue::Bool(*flag),
        (FieldKind::Integer, Value::Number(number)) => {
            ElicitationValue::Integer(whole_number(number).ok_or_else(malformed)?)
        }
        (FieldKind::Number, Value::Number(number)) => match number.as_i64() {
            Some(integer) => ElicitationValue::Integer(integer),
            None => ElicitationValue::Number(number.as_f64().ok_or_else(malformed)?),
        },
        (FieldKind::MultipleChoice, Value::Array(values)) => ElicitationValue::TextList(
            values
                .iter()
                .map(|value| value.as_str().map(str::to_owned))
                .collect::<Option<_>>()
                .ok_or_else(malformed)?,
        ),
        _ => return Err(malformed()),
    };
    Ok(Some(answer))
}

impl FormField {
    /// Drops a default that is not itself a valid answer, so a form never starts out answered
    /// with something it would refuse.
    fn without_invalid_default(mut self) -> Self {
        if self
            .default_value
            .as_ref()
            .is_some_and(|value| self.validate(Some(value)).is_err())
        {
            self.default_value = None;
        }
        self
    }
}

/// Whether a question offers no options: `options` absent, `null` or empty.
const fn has_no_options(options: Option<&Value>) -> bool {
    match options {
        None | Some(Value::Null) => true,
        Some(Value::Array(options)) => options.is_empty(),
        Some(_) => false,
    }
}

fn question_options(
    title: &str,
    raw_options: Option<&Value>,
) -> Result<Vec<FormOption>, FormError> {
    let malformed_options = || FormError::MalformedOptions {
        field: title.to_owned(),
    };
    let raw_options = raw_options
        .and_then(Value::as_array)
        .filter(|options| options.len() <= MAX_FIELD_OPTIONS)
        .ok_or_else(malformed_options)?;
    let options = raw_options
        .iter()
        .map(|raw| {
            let option = raw.as_object().ok_or_else(malformed_options)?;
            let label = option
                .get("label")
                .and_then(Value::as_str)
                .filter(|label| !label.is_empty())
                .ok_or_else(malformed_options)?;
            let text = |key: &str| {
                option
                    .get(key)
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_owned()
            };
            Ok(FormOption {
                value: label.to_owned(),
                label: label.to_owned(),
                detail: text("description"),
                preview: text("preview"),
            })
        })
        .collect::<Result<Vec<_>, FormError>>()?;
    let distinct: BTreeSet<&str> = options.iter().map(|option| option.value.as_str()).collect();
    if distinct.len() != options.len() {
        return Err(malformed_options());
    }
    Ok(options)
}

/// One question, always required. With options it takes one of them (several with
/// `multiSelect`), plus a typed answer unless `isOther` is `false`. A single-select question with
/// no options and `isOther: true` takes free text, prefilled from `textInput.default` when sent;
/// without `isOther: true` it has nothing to answer with and is malformed. `acceptsNotes: true`
/// lets the answer carry a note.
fn parse_question(index: usize, question: &Value) -> Result<FormField, FormError> {
    let malformed = || FormError::MalformedQuestion { index };
    let object = question.as_object().ok_or_else(malformed)?;
    let title = object
        .get("question")
        .and_then(Value::as_str)
        .filter(|title| !title.is_empty())
        .ok_or_else(malformed)?;
    let flag = |name: &str| object.get(name).and_then(Value::as_bool);
    let multi = flag("multiSelect") == Some(true);
    let is_other = flag("isOther");
    let raw_options = object.get("options");
    let supplied_id = object.get("id").and_then(Value::as_str).unwrap_or_default();
    let field = FormField {
        key: if supplied_id.is_empty() {
            title
        } else {
            supplied_id
        }
        .to_owned(),
        title: title.to_owned(),
        detail: object
            .get("header")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned(),
        is_secret: flag("isSecret") == Some(true),
        accepts_notes: flag("acceptsNotes") == Some(true),
        ..FormField::new(String::new(), String::new(), FieldKind::Text)
    };
    if has_no_options(raw_options) {
        if is_other != Some(true) || multi {
            return Err(FormError::MalformedOptions {
                field: title.to_owned(),
            });
        }
        let prefill = object
            .get("textInput")
            .and_then(|input| input.get("default"))
            .and_then(Value::as_str)
            .map(|text| ElicitationValue::Text(text.to_owned()));
        return Ok(FormField {
            default_value: prefill,
            ..field
        }
        .without_invalid_default());
    }
    Ok(FormField {
        kind: if multi {
            FieldKind::MultipleChoice
        } else {
            FieldKind::SingleChoice
        },
        options: question_options(title, raw_options)?,
        allows_custom: is_other != Some(false),
        ..field
    })
}

impl fmt::Display for FieldKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::Text => "text",
            Self::Number => "number",
            Self::Integer => "integer",
            Self::Boolean => "boolean",
            Self::SingleChoice => "single choice",
            Self::MultipleChoice => "multiple choice",
        })
    }
}
