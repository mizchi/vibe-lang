function canonicalValue(value) {
  if (value === null || typeof value === "boolean" || typeof value === "string") {
    return JSON.stringify(value);
  }
  if (typeof value === "number") {
    if (!Number.isFinite(value)) throw new TypeError("canonical JSON requires finite numbers");
    return JSON.stringify(value);
  }
  if (Array.isArray(value)) {
    return `[${value.map(canonicalValue).join(",")}]`;
  }
  if (typeof value === "object") {
    const prototype = Object.getPrototypeOf(value);
    if (prototype !== Object.prototype && prototype !== null) {
      throw new TypeError("canonical JSON requires plain objects");
    }
    return `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${canonicalValue(value[key])}`).join(",")}}`;
  }
  throw new TypeError(`unsupported canonical JSON value: ${typeof value}`);
}

export function canonicalJson(value) {
  return canonicalValue(value);
}
