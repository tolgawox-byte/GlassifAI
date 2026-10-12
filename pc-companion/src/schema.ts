// A small JSON-schema subset for tool arguments: enough to reject wrong types,
// unknown fields and oversized values before any tool code runs.

export interface JsonSchema {
  type: "object" | "string" | "integer" | "number" | "boolean" | "array";
  description?: string;
  properties?: Record<string, JsonSchema>;
  required?: string[];
  additionalProperties?: boolean;
  minLength?: number;
  maxLength?: number;
  pattern?: string;
  enum?: string[];
  minimum?: number;
  maximum?: number;
  items?: JsonSchema;
  maxItems?: number;
  default?: unknown;
}

export function validate(schema: JsonSchema, value: unknown, at = "arguments"): string[] {
  const errors: string[] = [];
  switch (schema.type) {
    case "object": {
      if (!value || typeof value !== "object" || Array.isArray(value)) {
        errors.push(`${at} bir nesne olmalı`);
        break;
      }
      const record = value as Record<string, unknown>;
      for (const key of schema.required ?? []) {
        if (record[key] === undefined || record[key] === null) errors.push(`${at}.${key} gerekli`);
      }
      for (const [key, child] of Object.entries(record)) {
        const childSchema = schema.properties?.[key];
        if (!childSchema) {
          if (schema.additionalProperties === false) errors.push(`${at}.${key} tanınmayan alan`);
          continue;
        }
        if (child === undefined || child === null) continue;
        errors.push(...validate(childSchema, child, `${at}.${key}`));
      }
      break;
    }
    case "string": {
      if (typeof value !== "string") {
        errors.push(`${at} metin olmalı`);
        break;
      }
      if (schema.minLength !== undefined && value.length < schema.minLength) errors.push(`${at} çok kısa`);
      if (schema.maxLength !== undefined && value.length > schema.maxLength) errors.push(`${at} çok uzun (en çok ${schema.maxLength})`);
      if (schema.enum && !schema.enum.includes(value)) errors.push(`${at} şunlardan biri olmalı: ${schema.enum.join(", ")}`);
      if (schema.pattern && !new RegExp(schema.pattern, "u").test(value)) errors.push(`${at} biçimi geçersiz`);
      break;
    }
    case "integer":
    case "number": {
      if (typeof value !== "number" || !Number.isFinite(value) || (schema.type === "integer" && !Number.isInteger(value))) {
        errors.push(`${at} ${schema.type === "integer" ? "tam sayı" : "sayı"} olmalı`);
        break;
      }
      if (schema.minimum !== undefined && value < schema.minimum) errors.push(`${at} en az ${schema.minimum} olmalı`);
      if (schema.maximum !== undefined && value > schema.maximum) errors.push(`${at} en çok ${schema.maximum} olmalı`);
      break;
    }
    case "boolean":
      if (typeof value !== "boolean") errors.push(`${at} true/false olmalı`);
      break;
    case "array": {
      if (!Array.isArray(value)) {
        errors.push(`${at} liste olmalı`);
        break;
      }
      if (schema.maxItems !== undefined && value.length > schema.maxItems) errors.push(`${at} en çok ${schema.maxItems} öğe içerebilir`);
      if (schema.items) value.forEach((item, index) => errors.push(...validate(schema.items as JsonSchema, item, `${at}[${index}]`)));
      break;
    }
  }
  return errors;
}

/** Fills in schema defaults for missing top-level fields. */
export function withDefaults(schema: JsonSchema, value: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = { ...value };
  for (const [key, child] of Object.entries(schema.properties ?? {})) {
    if ((out[key] === undefined || out[key] === null) && child.default !== undefined) out[key] = child.default;
  }
  return out;
}
