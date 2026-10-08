## 0.2.0

- `headers:` on `with_gcs_file` and `with_signed_post_url` for things the session start carries, such as customer-supplied encryption keys, `Content-Disposition` or `x-goog-meta-*` metadata

## 0.1.0

- Initial release: `ByteChunker`, `ResumableUpload` with `with_gcs_file`, `with_signed_post_url` and `with_session_url`, also aliased on `GCSPut`, and the IAM-backed signer for workload identity
- Pluggable transports, with `Net::HTTP` and Faraday included
