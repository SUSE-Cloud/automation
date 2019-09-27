#!/bin/bash
# requires openssl.conf inside this directory or a default one will
# be generated in it's place.

if [ $# -lt 3 ]; then
    echo "usage: $0 COUNTRY PROVINCE DOMAIN [CERTIFICATE_PASSWORD]"
    exit 1
fi

set -x -e

country=$1
province=$2
domain=$3

if [ $# -eq 4 ]; then
    pass=$4
else
    echo "Please enter the certificate password followed by ENTER:"
    read -r pass
fi

cert_path="."

subj="/C=$country/ST=$province/L=Ocala/O=Home/CN=$domain"

# Make directories for the two certificate authorities.
cd $cert_path
mkdir client_ca
mkdir server_ca

# Create an openssl.conf if one doesn't already exist in this
# directory. The configuration is taken from
# https://docs.openstack.org/octavia/latest/admin/guides/certificates.html
if [ ! -e openssl.cnf ]; then
    cat > openssl.cnf << EOF
# OpenSSL root CA configuration file.

[ ca ]
# \`man ca\`
default_ca = CA_default

[ CA_default ]
# Directory and file locations.
dir               = ./
certs             = \$dir/certs
crl_dir           = \$dir/crl
new_certs_dir     = \$dir/newcerts
database          = \$dir/index.txt
serial            = \$dir/serial
RANDFILE          = \$dir/private/.rand

# The root key and root certificate.
private_key       = \$dir/private/ca.key.pem
certificate       = \$dir/certs/ca.cert.pem

# For certificate revocation lists.
crlnumber         = \$dir/crlnumber
crl               = \$dir/crl/ca.crl.pem
crl_extensions    = crl_ext
default_crl_days  = 30

# SHA-1 is deprecated, so use SHA-2 instead.
default_md        = sha256

name_opt          = ca_default
cert_opt          = ca_default
default_days      = 3650
preserve          = no
policy            = policy_strict

[ policy_strict ]
# The root CA should only sign intermediate certificates that match.
# See the POLICY FORMAT section of \`man ca\`.
countryName             = match
stateOrProvinceName     = match
organizationName        = match
organizationalUnitName  = optional
commonName              = supplied
emailAddress            = optional

[ req ]
# Options for the \`req\` tool (\`man req\`).
default_bits        = 2048
distinguished_name  = req_distinguished_name
string_mask         = utf8only

# SHA-1 is deprecated, so use SHA-2 instead.
default_md          = sha256

# Extension to add when the -x509 option is used.
x509_extensions     = v3_ca

[ req_distinguished_name ]
# See <https://en.wikipedia.org/wiki/Certificate_signing_request>.
countryName                     = Country Name (2 letter code)
stateOrProvinceName             = State or Province Name
localityName                    = Locality Name
0.organizationName              = Organization Name
organizationalUnitName          = Organizational Unit Name
commonName                      = Common Name
emailAddress                    = Email Address

# Optionally, specify some defaults.
countryName_default             = AU
stateOrProvinceName_default     = NSW
localityName_default            =
0.organizationName_default      = OpenStack
organizationalUnitName_default  = Octavia
emailAddress_default            =
commonName_default              = example.org

[ v3_ca ]
# Extensions for a typical CA (\`man x509v3_config\`).
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints = critical, CA:true
keyUsage = critical, digitalSignature, cRLSign, keyCertSign

[ usr_cert ]
# Extensions for client certificates (\`man x509v3_config\`).
basicConstraints = CA:FALSE
nsCertType = client, email
nsComment = "OpenSSL Generated Client Certificate"
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
keyUsage = critical, nonRepudiation, digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth, emailProtection

[ server_cert ]
# Extensions for server certificates (\`man x509v3_config\`).
basicConstraints = CA:FALSE
nsCertType = server
nsComment = "OpenSSL Generated Server Certificate"
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer:always
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth

[ crl_ext ]
# Extension for CRLs (\`man x509v3_config\`).
authorityKeyIdentifier=keyid:always
EOF
fi

# Starting with the server certificate authority, prepare the CA.
pushd server_ca
mkdir certs crl newcerts private
chmod 700 private
touch index.txt
echo 1000 > serial

# Create the server CA key.
openssl genrsa -aes256 -out private/ca.key.pem -passout pass:$pass 4096
chmod 400 private/ca.key.pem

# Create the server CA certificate.
openssl req -key private/ca.key.pem -new -x509 -days 7300 -sha256 \
    -subj "$subj" -passin pass:$pass -extensions v3_ca -out certs/ca.cert.pem

popd

# Moving to the client certificate authority, prepare the CA.
pushd client_ca
mkdir certs crl csr newcerts private
chmod 700 private
touch index.txt
echo 1000 > serial

# Create the client CA key.
openssl genrsa -aes256 -out private/ca.key.pem -passout pass:$pass 4096
chmod 400 private/ca.key.pem

# Create the client CA certificate.
openssl req -key private/ca.key.pem -new -x509 -days 7300 -sha256 \
    -subj "$subj" -passin pass:$pass -extensions v3_ca -out certs/ca.cert.pem

# Create a key for the client certificate to use.
openssl genrsa -aes256 -out private/client.key.pem -passout pass:$pass 2048

#Create the certificate request for the client certificate used on the controllers.
openssl req -new -sha256 -key private/client.key.pem \
    -subj "$subj" -passin pass:$pass -extensions v3_ca -out csr/client.csr.pem

# Sign the client certificate request.
openssl ca -config ../openssl.cnf -batch -extensions usr_cert -days 7300 -notext -md sha256 \
    -in csr/client.csr.pem -subj "$subj" -passin pass:$pass -out certs/client.cert.pem

# Create a concatenated client certificate and key file.
openssl rsa -in private/client.key.pem -passin pass:$pass -out private/client.cert-and-key.pem
cat certs/client.cert.pem >> private/client.cert-and-key.pem
chmod 700 private/client.cert-and-key.pem
