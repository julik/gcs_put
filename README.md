# gcs_put

Streaming uploads to Google Cloud Storage when you do not know the size in advance.

The official `google-cloud-storage` gem can only upload things it can measure up front. It sends the total size when it opens the resumable session, and builds a `Content-Range` with that total on every chunk. Hand it a pipe or a socket and it has nothing to measure. GCS itself has supported resumable uploads of unknown size for years. This gem uses that: it gives you a writable object, chops what you write into 256 KiB-aligned chunks, and PUTs them into a resumable upload session as you go. Generating a zip, a CSV export or a transcode straight into a bucket works without a temp file.

## Installation

```ruby
gem "gcs_put"
```

## Usage

```ruby
require "gcs_put"

storage = Google::Cloud::Storage.new
bucket = storage.bucket("my-bucket")
file = bucket.file("exports/report.csv.gz", skip_lookup: true) # does not need to exist

GcsPut::ResumableUpload.new(file, content_type: "application/gzip").stream do |io|
  gz = Zlib::GzipWriter.new(io)
  rows.each { |row| gz.write(row.to_csv) }
  gz.finish
end
```

The object yielded to the block responds to `write` and `<<`, so anything that writes to an IO can write to it, including `IO.copy_stream`, `Zlib::GzipWriter` and `ZipKit::Streamer`. The last chunk is sent when the block returns. If the block raises, nothing is finalized and the session simply expires after a week.

`stream` returns the total number of bytes uploaded.

### Chunk size

Every chunk except the last is held in memory and must be a multiple of 256 KiB. The default is 5 MB. Larger chunks mean fewer requests:

```ruby
GcsPut::ResumableUpload.new(file, chunk_size: 32 * 1024 * 1024)
```

### Using the parts separately

The session URL is just a string. Once you have it, uploading needs no Google credentials at all, so a web process can sign and a worker can upload, or several processes can pick up the same session:

```ruby
session_url = GcsPut::ResumableUpload.new(file).start_session

# Elsewhere, no SDK needed
io = GcsPut::RangedPutIO.new(session_url, content_type: "binary/octet-stream")
io.write(bytes)
io.finish
```

If you already have a signed POST URL from somewhere else:

```ruby
session_url = GcsPut::ResumableUpload.start_session(signed_post_url, content_type: "binary/octet-stream")
```

The chunker is also usable on its own, for anything that needs evenly sized pieces:

```ruby
chunker = GcsPut::ByteChunker.new(chunk_size: 1024) { |bytes, is_last| ... }
chunker << data
chunker.finish
```

### Transports

HTTP goes through a small transport object. The default uses `Net::HTTP` with one persistent connection and needs nothing installed. To use Faraday instead, pass a transport wrapping your own connection, so you get to pick the adapter, timeouts and instrumentation:

```ruby
conn = Faraday.new { |f| f.options.timeout = 120 }
transport = GcsPut::Transport::Faraday.new(conn)

GcsPut::ResumableUpload.new(file, transport: transport).stream { |io| ... }
GcsPut::RangedPutIO.new(session_url, transport: transport)
```

Without an argument the Faraday transport makes a default connection. The `raise_error` middleware is tolerated. Timeouts and connection errors for `Net::HTTP` can be set on its transport too:

```ruby
GcsPut::Transport::NetHTTP.new(open_timeout: 10, read_timeout: 120)
```

Anything responding to `put(uri, body, headers)`, `post(uri, body, headers)` and `close` works as a transport. The verbs must return something with `status`, `body` and a case-insensitive `[]` for headers, and raise `GcsPut::TransientError` for failures worth retrying. Every chunk carries a `Content-MD5`, so an adapter that mangles request bodies fails loudly at upload time rather than quietly at download time. [httpx 1.4.0 did exactly that](https://gitlab.com/os85/httpx/-/issues/338).

### Retries

A chunk which fails with a connection error or a 5xx is not resent from the start. The session is asked how many bytes it has, and only the remainder goes out again. The same happens when GCS answers a PUT with a `Range` header showing it took fewer bytes than were sent. A chunk is given up on after 5 attempts, configurable via `max_attempts:` on `RangedPutIO`. A 4xx fails immediately.

## Permissions

Starting a session needs a signed POST URL, and signing needs a private key.

**With a service account JSON key** (`GOOGLE_APPLICATION_CREDENTIALS` or `credentials:` on `Google::Cloud::Storage.new`) the key is local, the SDK signs with it, and the only permission needed is `storage.objects.create` on the bucket. Nothing else to do.

**Under workload identity** on GCE, GKE, Cloud Run or Cloud Functions there is no private key on the machine. The gem detects this and asks the IAM Credentials API to sign on the service account's behalf via `signBlob`. For that call to be allowed, the service account must hold the `roles/iam.serviceAccountTokenCreator` role **on itself**:

```sh
gcloud iam service-accounts add-iam-policy-binding SA_EMAIL \
  --member="serviceAccount:SA_EMAIL" \
  --role="roles/iam.serviceAccountTokenCreator"
```

Without it, `start_session` fails with a permission error from the IAM API, not from Cloud Storage, which is confusing the first time. The background is in [google-cloud-ruby#13307](https://github.com/googleapis/google-cloud-ruby/issues/13307). The IAM Credentials API must also be enabled on the project.

Any extra options such as `expires:` or `issuer:` and `signer:` of your own are passed through to `file.signed_url`.

## Running the tests

```sh
bundle exec rake
```

Unit tests stub HTTP and need nothing. The live tests run against a real bucket when `GCS_PUT_TEST_BUCKET` is set along with working credentials. Objects they create are deleted afterwards.

## Resources

- [Performing resumable uploads](https://cloud.google.com/storage/docs/performing-resumable-uploads)
- [Signed URLs with resumable uploads](https://cloud.google.com/storage/docs/access-control/signed-urls#signing-resumable)
- Google's own [stream_upload.rb gist](https://gist.github.com/frankyn/9a5344d1b19ed50ebbf9f15f0ff92032), which this gem started from

## License

MIT
