# frozen_string_literal: true

module GcsPut::Signer
  # When running on GCE, GKE, Cloud Run etc. under a service account there is no private key
  # on the box to sign the URL with. The SDK then needs an `issuer` (the account email) and a
  # `signer` lambda which asks the IAM credentials API to sign for us. For that to be allowed the
  # service account must have `roles/iam.serviceAccountTokenCreator` on itself.
  # Lifted from https://github.com/googleapis/google-cloud-ruby/issues/13307#issuecomment-1894546343
  #
  # @return [Hash] either `{issuer:, signer:}` or an empty hash when not on compute engine
  def self.url_issuer_and_signer
    require "google/cloud/env"
    env = Google::Cloud.env
    return {} unless env.compute_engine?

    issuer = env.lookup_metadata("instance", "service-accounts/default/email")
    {issuer: issuer, signer: iam_signer_for(issuer)}
  end

  # @param service_account_email[String]
  # @return [Proc] a lambda which takes the string to sign and returns the signature
  def self.iam_signer_for(service_account_email)
    lambda do |string_to_sign|
      require "google/apis/iamcredentials_v1"
      require "googleauth"

      iam_client = Google::Apis::IamcredentialsV1::IAMCredentialsService.new
      iam_client.authorization = Google::Auth.get_application_default(["https://www.googleapis.com/auth/iam"])
      request = Google::Apis::IamcredentialsV1::SignBlobRequest.new(payload: string_to_sign)
      response = iam_client.sign_service_account_blob("projects/-/serviceAccounts/#{service_account_email}", request)
      response.signed_blob
    end
  end
end
