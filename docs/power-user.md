# Advanced Configuration

The Unraid template exposes upstream Penpot settings as Advanced options. Dropdowns are used where valid values are known.

## Flags

Leave `PENPOT_FLAGS` blank to use `PENPOT_AIO_DEFAULT_FLAGS` plus per-flag dropdown controls. Set `PENPOT_FLAGS` to supply upstream flags directly. The AIO disables Penpot's Admin Console after applying flag overrides.

Default AIO flags:

- `disable-email-verification`
- `enable-smtp`
- `disable-secure-session-cookies`
- `enable-mcp`
- `disable-admin-console`

## Storage

Filesystem storage is the default and uses `/appdata/assets`. S3-compatible storage requires `PENPOT_OBJECTS_STORAGE_BACKEND=s3` plus the matching bucket, endpoint, region, and credentials.

## Auth

GitHub, GitLab, Google, OIDC, LDAP, domain allow/block lists, and cookie controls are exposed in Advanced View. Configure the matching login flags when enabling provider-based login.

## MCP

MCP runs internally by default. When the bundled service and Penpot's `enable-mcp` flag are enabled, the frontend proxies `/mcp/stream`, `/mcp/sse`, and `/mcp/ws`. Direct host ports for `4401` and `4402` are optional and blank by default.
