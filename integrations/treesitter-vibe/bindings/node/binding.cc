#include <napi.h>

typedef struct TSLanguage TSLanguage;

extern "C" TSLanguage *tree_sitter_vibe();

static napi_value Init(napi_env env, napi_value exports) {
  napi_value language;
  napi_status status =
      napi_create_external(env, tree_sitter_vibe(), NULL, NULL, &language);
  if (status != napi_ok) {
    napi_throw_error(env, NULL, "Failed to create external");
    return exports;
  }
  status = napi_set_named_property(env, exports, "language", language);
  if (status != napi_ok) {
    napi_throw_error(env, NULL, "Failed to set language property");
  }

  napi_value name;
  status = napi_create_string_utf8(env, "vibe", NAPI_AUTO_LENGTH, &name);
  if (status != napi_ok) {
    napi_throw_error(env, NULL, "Failed to create name string");
    return exports;
  }
  status = napi_set_named_property(env, exports, "name", name);
  if (status != napi_ok) {
    napi_throw_error(env, NULL, "Failed to set name property");
  }

  return exports;
}

NAPI_MODULE(tree_sitter_vibe_binding, Init)
