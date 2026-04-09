# OpenAPI 3.1.0 Reference Notes

## Schema Object - Composition

- **anyOf**: Validates if ANY of the given schemas match. Multiple can match.
- **oneOf**: Validates if EXACTLY ONE of the given schemas matches.
- **allOf**: Validates if ALL of the given schemas match. Used for composition/inheritance.
- **nullable**: In 3.1, follows JSON Schema 2020-12. Use `type: [string, 'null']` instead of `nullable: true`. In 3.0, `nullable: true` is the keyword. Composition schemas (allOf/oneOf/anyOf) can be nullable.

## Path Item Object

- **$ref**: `string` - Allows for a referenced definition of this path item. The referenced structure MUST be in the form of a Path Item Object. If both the $ref and the path item have fields, behavior is undefined.
- **servers**: `[Server Object]` - An alternative server array to service all operations in this path.
- Path items can be defined in `components/pathItems` and referenced via `$ref`.

## Components Object

- **pathItems**: `Map[string, Path Item Object | Reference Object]` - Reusable Path Item Objects.
- All component keys MUST match: `^[a-zA-Z0-9\.\-_]+$`

## Security Requirement Object

- **OR semantics**: The top-level security array uses OR - any ONE requirement suffices.
- **AND semantics**: Within a single SecurityRequirement, ALL listed schemes must be satisfied.
- Each scheme maps to a list of scopes (for OAuth2/OpenID). Empty list means no specific scopes required.

## Parameter Object - deepObject Style

- `style: deepObject` provides rendering of nested objects using form parameters.
- Only applies to `query` parameters.
- Rendering: `color[R]=100&color[G]=200&color[B]=150`
- For nested objects: `filter[meta][name]=value`
- `explode` defaults to true; cannot be false for deepObject.

## Required Fields (per spec)

- **OpenAPI Object**: `openapi` (REQUIRED), `info` (REQUIRED). `paths` is optional in 3.1 but REQUIRED in 3.0.
- **Request Body Object**: `content` is REQUIRED.
- **Response Object**: `description` is REQUIRED.
- **Parameter Object**: `name` and `in` are REQUIRED. One of `schema` or `content` is REQUIRED.

## Parameter Object - allowReserved

- `allowReserved: boolean` - Default false. When true, allows reserved characters `:/?#[]@!$&'()*+,;=` to be sent WITHOUT percent-encoding.
- Only applies to `query` parameters.
- When false (default), values MUST be percent-encoded.

## Discriminator Object

- Used with oneOf or anyOf to aid deserialization.
- `propertyName`: REQUIRED. Name of the property in the payload that distinguishes types.
- `mapping`: Optional map of payload values to schema names or `$ref` strings.
- Applies equally to oneOf and anyOf.
