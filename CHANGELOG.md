## 0.1.0

- Initial release: `ByteChunker`, `ResumableUpload` with `to_gcs_file`, `to_signed_post_url` and `to_session_url`, also aliased on `GCSPut`, and the IAM-backed signer for workload identity
- Pluggable transports, with `Net::HTTP` and Faraday included
