package hostcredentials_test

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"testing"
	"time"
)

// certificate creates synthetic credentials; signing keys never leave test memory.
func certificate(t *testing.T, template *x509.Certificate, parent *x509.Certificate, signer *ecdsa.PrivateKey) ([]byte, *ecdsa.PrivateKey) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		panic(err)
	}
	if parent == nil {
		parent, signer = template, key
	}
	der, err := x509.CreateCertificate(rand.Reader, template, parent, &key.PublicKey, signer)
	if err != nil {
		panic(err)
	}
	return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), key
}

func credentials(t *testing.T, endpoint string, change func(*x509.Certificate)) (ca, identity []byte, expectedName string) {
	t.Helper()
	now := time.Now()
	root := &x509.Certificate{
		SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "synthetic-ca"},
		IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign,
		NotBefore: now.Add(-time.Hour), NotAfter: now.Add(time.Hour),
	}
	ca, signer := certificate(t, root, nil, nil)
	leaf := &x509.Certificate{
		SerialNumber: big.NewInt(2), Subject: pkix.Name{CommonName: "json-keys-database"},
		NotBefore: root.NotBefore, NotAfter: root.NotAfter,
		KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth},
	}
	if endpoint == "repository" {
		leaf.Subject.CommonName = "agora-pgbackrest-json-keys.internal"
		leaf.DNSNames = []string{leaf.Subject.CommonName}
		leaf.ExtKeyUsage = []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}
	}
	expectedName = leaf.Subject.CommonName
	if change != nil {
		change(leaf)
	}
	identity, key := certificate(t, leaf, root, signer)
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		panic(err)
	}
	return ca, append(identity, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})...), expectedName
}
