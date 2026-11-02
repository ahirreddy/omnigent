#include "core/json.h"
#include "test.h"

using rb::Json;

TEST(JsonParsesAndDumpsCompactSortedKeys) {
  std::string error;
  auto value = Json::Parse(R"({"b": [1, 2.5, true, null], "a": "x\u00e9\n"})", &error);
  CHECK_MSG(value.has_value(), error);
  CHECK_EQ(value->Dump(), std::string("{\"a\":\"x\xc3\xa9\\n\",\"b\":[1,2.5,true,null]}"));
  CHECK_EQ(*value->Find("b")->as_array()[0].as_integer(), 1);
}

TEST(JsonRejectsMalformedInput) {
  std::string error;
  CHECK(!Json::Parse("{\"a\":}", &error));
  CHECK(!Json::Parse("[1,]", &error));
  CHECK(!Json::Parse("\"\\ud800\"", &error));
  CHECK(!Json::Parse("01", &error));
  CHECK(!Json::Parse("{} x", &error));
  CHECK(!error.empty());
}

TEST(JsonSurrogatePairsDecodeToUtf8) {
  std::string error;
  auto value = Json::Parse(R"("\ud83d\ude00")", &error);
  CHECK(value.has_value());
  CHECK_EQ(value->as_string(), std::string("\xF0\x9F\x98\x80"));
}

TEST(JsonCopiesDoNotShareMutations) {
  Json original = Json::MakeObject();
  original.Set("a", 1);
  Json copy = original;
  copy.Set("b", 2);
  CHECK(original.Find("b") == nullptr);
  CHECK(copy.Find("a") != nullptr);
}

TEST(JsonIntegerAndDoubleCompareByValue) {
  std::string error;
  CHECK(*Json::Parse("1", &error) == Json(1.0));
  CHECK(*Json::Parse("640.5", &error) == Json(640.5));
}
