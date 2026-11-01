//! Typed decision forms: a flat MCP `requestedSchema` or an `AskUserQuestion` payload becomes a
//! [`DecisionForm`], and answers are validated against it without coercion.
//!
//! Port of `NativeLab`'s `DecisionForm.swift`. Anything the native form cannot express exactly
//! (nested objects, `pattern`, unions, malformed constraints) is a [`FormError`]: it never turns
//! into a less restrictive form or a binary approval.

use std::collections::{BTreeMap, BTreeSet};
use std::fmt;

use omnigent_protocol::ElicitationValue;
use serde_json::{Map, Number, Value};

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
const PROPERTY_KEYS: [&str; 14] = [
    "type",
    "title",
    "description",
    "enum",
    "enumNames",
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
const ITEMS_KEYS: [&str; 3] = ["type", "enum", "enumNames"];

/// One choice a field offers.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FormOption {
    /// The value posted when chosen.
    pub value: String,
    /// What to show; the value unless the schema named it.
    pub label: String,
    /// Extra description (question option `description` and `preview`).
    pub detail: String,
}

impl FormOption {
    fn plain(value: String) -> Self {
        Self {
            label: value.clone(),
            value,
            detail: String::new(),
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
            minimum: None,
            maximum: None,
            min_length: None,
            max_length: None,
            min_items: None,
            max_items: None,
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
        if let Some(key) = values
            .keys()
            .find(|key| !self.fields.iter().any(|field| &field.key == *key))
        {
            return Err(AnswerError::UnknownField { key: key.clone() });
        }
        self.fields
            .iter()
            .try_for_each(|field| field.validate(values.get(&field.key)))
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

    /// Parses an `AskUserQuestion` payload (`{"questions": [...]}`). Every question is required
    /// and accepts a custom answer.
    ///
    /// # Errors
    ///
    /// [`FormError`] for a payload without questions, a question without text or options, or
    /// duplicate options or keys.
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
    /// A property keyword the form cannot honour (for example `pattern` or `format`).
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

fn choice_options(key: &str, property: &Map<String, Value>) -> Result<Vec<FormOption>, FormError> {
    let labels = enum_labels(property);
    Ok(string_options(key, property.get("enum"))?
        .into_iter()
        .enumerate()
        .map(|(index, value)| {
            let label = labels.get(index).cloned().flatten();
            FormOption {
                label: label.unwrap_or_else(|| value.clone()),
                value,
                detail: String::new(),
            }
        })
        .collect())
}

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
    if items.get("type").and_then(Value::as_str) != Some("string") {
        return Err(FormError::UnsupportedType {
            field: key.to_owned(),
            type_name: "array of non-strings".to_owned(),
        });
    }
    Ok(string_options(key, items.get("enum"))?
        .into_iter()
        .map(FormOption::plain)
        .collect())
}

fn property_kind(
    key: &str,
    property: &Map<String, Value>,
) -> Result<(FieldKind, Vec<FormOption>), FormError> {
    let declared = match property.get("type") {
        None if property.contains_key("enum") => "string",
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
        "string" if property.contains_key("enum") => {
            (FieldKind::SingleChoice, choice_options(key, property)?)
        }
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
    if property.contains_key("enum") && kind != FieldKind::SingleChoice {
        return Err(FormError::ConstraintNotApplicable {
            field: key.to_owned(),
            keyword: "enum".to_owned(),
        });
    }
    Ok((kind, options))
}

fn check_applicable(
    key: &str,
    property: &Map<String, Value>,
    kind: FieldKind,
) -> Result<(), FormError> {
    let groups: [(&[&str], bool); 3] = [
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
        minimum,
        maximum,
        min_length,
        max_length,
        min_items,
        max_items,
    })
}

fn parse_question(index: usize, question: &Value) -> Result<FormField, FormError> {
    let malformed = || FormError::MalformedQuestion { index };
    let object = question.as_object().ok_or_else(malformed)?;
    let title = object
        .get("question")
        .and_then(Value::as_str)
        .filter(|title| !title.is_empty())
        .ok_or_else(malformed)?;
    let malformed_options = || FormError::MalformedOptions {
        field: title.to_owned(),
    };
    let raw_options = object
        .get("options")
        .and_then(Value::as_array)
        .filter(|options| !options.is_empty() && options.len() <= MAX_FIELD_OPTIONS)
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
            let detail: Vec<&str> = ["description", "preview"]
                .iter()
                .filter_map(|key| option.get(*key).and_then(Value::as_str))
                .collect();
            Ok(FormOption {
                value: label.to_owned(),
                label: label.to_owned(),
                detail: detail.join("\n\n"),
            })
        })
        .collect::<Result<Vec<_>, FormError>>()?;
    let distinct: BTreeSet<&str> = options.iter().map(|option| option.value.as_str()).collect();
    if distinct.len() != options.len() {
        return Err(malformed_options());
    }
    let supplied_id = object.get("id").and_then(Value::as_str).unwrap_or_default();
    let multi = object.get("multiSelect") == Some(&Value::Bool(true));
    Ok(FormField {
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
        kind: if multi {
            FieldKind::MultipleChoice
        } else {
            FieldKind::SingleChoice
        },
        options,
        allows_custom: true,
        is_secret: object.get("isSecret") == Some(&Value::Bool(true)),
        ..FormField::new(String::new(), String::new(), FieldKind::Text)
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
