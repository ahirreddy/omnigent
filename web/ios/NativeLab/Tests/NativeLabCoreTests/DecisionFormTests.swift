import Foundation
import XCTest

@testable import NativeLabCore

final class DecisionFormTests: XCTestCase {
  func testTypedSchemaHasNativeFieldsAndValidatesWithoutCoercion() throws {
    let decision = try decode(
      #"{"requestedSchema":{"type":"object","required":["name","count","ready"],"properties":{"name":{"type":"string","minLength":2},"count":{"type":"integer","minimum":1,"maximum":5},"ready":{"type":"boolean"}}}}"#
    )
    let form = try XCTUnwrap(decision.form)
    XCTAssertNil(decision.unsupportedReason)
    XCTAssertNotNil(form.validationError(values: [:]))
    XCTAssertNil(
      form.validationError(values: [
        "name": .string("Omni"), "count": .number(2), "ready": .boolean(false),
      ]))
    XCTAssertNotNil(
      form.validationError(values: [
        "name": .string("O"), "count": .number(2), "ready": .boolean(false),
      ]))
    XCTAssertNotNil(
      form.validationError(values: [
        "name": .string("Omni"), "count": .number(2.5), "ready": .boolean(false),
      ]))
    XCTAssertNotNil(
      form.validationError(values: [
        "name": .string("Omni"), "count": .string("2"), "ready": .boolean(false),
      ]))
  }

  func testUnsupportedNestedSchemaNeverBecomesApproval() throws {
    let decision = try decode(
      #"{"requestedSchema":{"type":"object","properties":{"config":{"type":"object","properties":{"name":{"type":"string"}}}}}}"#
    )
    XCTAssertNotNil(decision.unsupportedReason)
    XCTAssertNil(decision.form)
  }

  func testUnsupportedPatternNeverSilentlyDisappears() throws {
    let decision = try decode(
      #"{"requestedSchema":{"type":"object","properties":{"name":{"type":"string","pattern":"^[a-z]+$"}}}}"#
    )
    XCTAssertNotNil(decision.unsupportedReason)
  }

  func testSchemaWithoutPropertiesAndMissingURLNeverBecomeApproval() throws {
    for params in [
      #"{"requestedSchema":{"type":"array","items":{"type":"string"}}}"#,
      #"{"requestedSchema":{"oneOf":[{"type":"string"},{"type":"number"}]}}"#,
      #"{"mode":"url"}"#,
      #"{"requestedSchema":"not a schema"}"#,
    ] {
      XCTAssertNotNil(try decode(params).unsupportedReason)
    }
  }

  func testMalformedConstraintsFailClosed() throws {
    for schema in [
      #"{"type":"object","required":"name","properties":{"name":{"type":"string"}}}"#,
      #"{"type":"object","properties":{"name":{"type":"string","minLength":2.5}}}"#,
      #"{"type":"object","properties":{"name":{"type":"string","minLength":-1}}}"#,
      #"{"type":"object","properties":{"count":{"type":"number","minimum":"5"}}}"#,
      #"{"type":"object","properties":{"count":{"type":"number","minimum":5,"maximum":1}}}"#,
    ] {
      XCTAssertNotNil(try decode("{\"requestedSchema\":\(schema)}").unsupportedReason)
    }
  }

  func testCommandPolicyAndMetadataRemainExplicit() throws {
    let request = try decode(
      #"{"command":"swift test","cwd":"/workspace","reason":"Verify the change","execpolicy_amendment":["swift","test"]}"#
    )
    XCTAssertEqual(request.execPolicyAmendment, ["swift", "test"])
    XCTAssertTrue(request.detail.contains("Working directory: /workspace"))
    XCTAssertTrue(request.detail.contains("Reason: Verify the change"))
  }

  func testArrayChoicesValidateCountAndMembership() throws {
    let decision = try decode(
      #"{"requestedSchema":{"type":"object","required":["tags"],"properties":{"tags":{"type":"array","minItems":1,"maxItems":2,"items":{"type":"string","enum":["One","Two","Three"]}}}}}"#
    )
    let form = try XCTUnwrap(decision.form)
    XCTAssertNil(form.validationError(values: ["tags": .strings(["One", "Two"])]))
    XCTAssertNotNil(form.validationError(values: ["tags": .strings(["Other"])]))
    XCTAssertNotNil(form.validationError(values: ["tags": .strings(["One", "Two", "Three"])]))
    XCTAssertNotNil(form.validationError(values: ["tags": .strings(["One", "One"])]))
  }

  func testAskUserQuestionPreservesIDsAndSupportsCustomAndMultiAnswers() throws {
    let decision = try decode(
      #"{"ask_user_question":{"questions":[{"id":"scope","question":"Which scope?","options":[{"label":"Native","description":"Phone UI"}],"multiSelect":false},{"question":"What next?","options":[{"label":"Tests"},{"label":"Docs"}],"multiSelect":true}]}}"#
    )
    let form = try XCTUnwrap(decision.form)
    XCTAssertEqual(form.fields.map(\.key), ["scope", "What next?"])
    XCTAssertEqual(form.fields[0].options.first?.detail, "Phone UI")
    XCTAssertNil(
      form.validationError(values: [
        "scope": .string("Custom answer"), "What next?": .strings(["Tests", "Accessibility"]),
      ]))
    XCTAssertNotNil(form.validationError(values: ["scope": .string("Native")]))
  }

  func testQuestionPreviewFallbackProducesForm() throws {
    let decision = try decode(
      #"{"content_preview":"AskUserQuestion({\"questions\":[{\"question\":\"Continue?\",\"options\":[{\"label\":\"Yes\"}],\"multiSelect\":false}]})"}"#
    )
    XCTAssertEqual(decision.form?.fields.first?.key, "Continue?")
  }

  func testMalformedQuestionCannotBecomeApproval() throws {
    let decision = try decode(
      #"{"ask_user_question":{"questions":[{"question":"Missing options"}]}}"#)
    XCTAssertNotNil(decision.unsupportedReason)
    XCTAssertNil(decision.form)
  }

  func testExternalRequestOnlyExposesSafeExplicitHandoff() throws {
    let decision = try decode(#"{"mode":"url","url":"https://example.invalid/confirm"}"#)
    XCTAssertEqual(decision.externalURL, "https://example.invalid/confirm")
    XCTAssertNotNil(decision.unsupportedReason)
    let unsafe = try decode(#"{"mode":"url","url":"javascript:alert(1)"}"#)
    XCTAssertNil(unsafe.externalURL)
    XCTAssertNotNil(unsafe.unsupportedReason)
  }

  func testPlanAndRememberCapabilitiesAreExplicit() throws {
    let plan = try decode(#"{"exit_plan_mode":{"plan":"Review this plan"}}"#)
    XCTAssertEqual(plan.isPlanReview, true)
    XCTAssertEqual(plan.allowAllEdits, true)
    let remember = try decode(#"{"remember_scope":{"tool":"WebFetch","host":"example.invalid"}}"#)
    XCTAssertEqual(remember.rememberLabel, "example.invalid")
  }

  func testDecisionValuesEncodeAsFlatMCPScalars() throws {
    let values: [String: DecisionValue] = [
      "name": .string("Omni"), "count": .number(2), "ready": .boolean(false),
      "tags": .strings(["Native"]),
    ]
    let encoded = try JSONEncoder().encode(values)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    XCTAssertEqual(object["name"] as? String, "Omni")
    XCTAssertEqual(object["count"] as? Double, 2)
    XCTAssertEqual(object["ready"] as? Bool, false)
    XCTAssertEqual(object["tags"] as? [String], ["Native"])
    XCTAssertEqual(try JSONDecoder().decode([String: DecisionValue].self, from: encoded), values)
  }

  func testUnknownResponseFieldIsRejected() {
    let form = DecisionForm(fields: [.init(key: "name", title: "Name", kind: .text)])
    XCTAssertNotNil(
      form.validationError(values: ["name": .string("Omni"), "extra": .boolean(true)]))
  }

  private func decode(_ params: String) throws -> DecisionRequest {
    let value = try JSONDecoder().decode(JSONValue.self, from: Data(params.utf8))
    return try ElicitationWire(
      value: .object(["elicitation_id": .string("request"), "params": value]), sessionID: "session"
    ).decision
  }
}
