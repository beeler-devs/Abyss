# Protocol Versioning

Current version: `1`

## Envelope Requirement

Every event envelope MUST include:

- `protocolVersion` (integer)

Bridge v0 enforces this on server ingress. Missing `protocolVersion` is rejected as `invalid_event`.

## Compatibility Rules

- Same major version: compatible unless explicitly documented otherwise.
- New event types: receivers must ignore unknown `type` values safely.
- New payload fields: receivers must ignore unknown fields.
- Removed or retyped required fields: requires protocol version bump.

## Upgrade Strategy

1. Add support for both old + new versions where possible.
2. Roll out clients that emit new version.
3. Enforce new version server-side after all active clients upgraded.

Bridge v0 starts at version `1`, with this policy in place for subsequent revisions.
