#!/usr/bin/env bash
set -eo pipefail

dir="$(dirname "$(readlink -f "$BASH_SOURCE")")"
testDir="$(readlink -f "$(dirname "$BASH_SOURCE")")"
testName="$(basename "$testDir")"

image="$1"
cliFlags=()

if [[ "$testName" == *tls* ]]; then
  valkeyCliHelp="$(docker run --rm --entrypoint valkey-cli "$image" --help 2>&1 || :)"
  if ! grep -q -- '--tls' <<<"$valkeyCliHelp"; then
    echo >&2 "skipping; not built with TLS support (possibly version < 6.0 or 32bit variant)"
    exit 0
  fi

  tlsImage="$("$testDir/../image-name.sh" librarytest/valkey-tls "$image")"
  "$testDir/../docker-build.sh" "$testDir" "$tlsImage" <<-EOD
		FROM alpine:3.19 AS certs
		RUN apk add --no-cache openssl
		RUN set -eux; \
			mkdir /certs; \
			openssl genrsa -out /certs/ca-private.key 8192; \
			openssl req -new -x509 \
				-key /certs/ca-private.key \
				-out /certs/ca.crt \
				-days $((365 * 30)) \
				-subj '/CN=lolca'; \
			openssl genrsa -out /certs/private.key 4096; \
			openssl req -new -key /certs/private.key \
				-out /certs/cert.csr -subj '/CN=valkey'; \
			openssl x509 -req -in /certs/cert.csr \
				-CA /certs/ca.crt -CAkey /certs/ca-private.key -CAcreateserial \
				-out /certs/cert.crt -days $((365 * 30)); \
			openssl verify -CAfile /certs/ca.crt /certs/cert.crt

		FROM $image
		COPY --from=certs --chown=valkey:valkey /certs /certs
		CMD [ \
			"--tls-port", "6379", "--port", "0", \
			"--tls-cert-file", "/certs/cert.crt", \
			"--tls-key-file", "/certs/private.key", \
			"--tls-ca-cert-file", "/certs/ca.crt" \
		]
	EOD

  image="$tlsImage"
  cliFlags+=(--tls --cert /certs/cert.crt --key /certs/private.key --cacert /certs/ca.crt)
fi

network="valkey-network-$RANDOM-$RANDOM"
docker network create "$network" >/dev/null

cname="valkey-container-$RANDOM-$RANDOM"
cid="$(docker run -d --name "$cname" --network "$network" "$image")"

trap "docker rm -vf '$cid' >/dev/null; docker network rm '$network' >/dev/null" EXIT

valkey-cli() {
  docker run --rm -i \
    --network "$network" \
    --entrypoint valkey-cli \
    "$image" \
    -h "$cname" \
    "${cliFlags[@]}" \
    "$@"
}

. "$dir/../../retry.sh" --tries 20 '[ "$(valkey-cli ping)" = "PONG" ]'

[ "$(valkey-cli set mykey somevalue)" = "OK" ]
[ "$(valkey-cli get mykey)" = "somevalue" ]
