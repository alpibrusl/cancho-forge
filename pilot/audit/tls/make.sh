#!/bin/sh
# Makes the audit's TLS fixtures (docs/pilot-audit.md section 3.1). Run ONCE by a person; the output is checked in, and nothing runs openssl at audit time.
#   ca.pem / ca.key       the test CA the checker is told to trust (--roots ca.pem)
#   id_valid/             a leaf for ok.test, notBefore 2026-01-01, notAfter 2035-01-01
#   id_wrongname/         a leaf for other.test, the same dates
#   id_selfsigned/        a self-signed leaf for ok.test, the same dates
# Each id_* holds `chain.pem`, `key.pem` (PKCS#8, ECDSA P-256) and `names`, the shape cancho's TLS server loads. Expiry cases need no fixture of their own: the checker's
# `--now` is set past notAfter (expired) or 10 / 14 days before it. These keys are throw-away and secure nothing; they are committed on purpose.
set -eu
cd "$(dirname "$0")"
rm -rf id_* ca.* work && mkdir work
openssl ecparam -name prime256v1 -genkey -noout -out ca.key
openssl req -x509 -new -key ca.key -sha256 -not_before 20260101000000Z -not_after 20450101000000Z -subj "/CN=pilot audit test CA" -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" -out ca.pem
leaf() { # id common-name
  mkdir "id_$1"
  openssl ecparam -name prime256v1 -genkey -noout -out "work/$1.key"
  openssl pkcs8 -topk8 -nocrypt -in "work/$1.key" -out "id_$1/key.pem"
  openssl req -new -key "work/$1.key" -subj "/CN=$2" -addext "subjectAltName=DNS:$2" -out "work/$1.csr"
  printf 'subjectAltName=DNS:%s\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature\nextendedKeyUsage=serverAuth\n' "$2" > "work/$1.ext"
  printf '%s' "$2" > "id_$1/names"
}
leaf valid ok.test; openssl x509 -req -in work/valid.csr -CA ca.pem -CAkey ca.key -CAcreateserial -not_before 20260101000000Z -not_after 20350101000000Z -extfile work/valid.ext -out work/valid.crt
cat work/valid.crt ca.pem > id_valid/chain.pem
leaf wrongname other.test; openssl x509 -req -in work/wrongname.csr -CA ca.pem -CAkey ca.key -CAcreateserial -not_before 20260101000000Z -not_after 20350101000000Z -extfile work/wrongname.ext -out work/wrongname.crt
cat work/wrongname.crt ca.pem > id_wrongname/chain.pem
leaf selfsigned ok.test; openssl x509 -req -in work/selfsigned.csr -signkey work/selfsigned.key -not_before 20260101000000Z -not_after 20350101000000Z -extfile work/selfsigned.ext -out id_selfsigned/chain.pem
rm -rf work ca.srl ca.key   # the CA key is not needed once the leaves are signed
echo "made: ca.pem id_valid id_wrongname id_selfsigned"
