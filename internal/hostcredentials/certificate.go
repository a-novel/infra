package hostcredentials

import (
	"bytes"
	"crypto/tls"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"time"
)

func validateCertificate(ca, identity []byte, config Config, now time.Time) error {
	roots := x509.NewCertPool()
	for len(bytes.TrimSpace(ca)) > 0 {
		block, rest := pem.Decode(ca)
		if block == nil || block.Type != "CERTIFICATE" || len(block.Headers) != 0 {
			return errors.New("trust bundle must contain only CA certificates")
		}
		certificate, err := x509.ParseCertificate(block.Bytes)
		if err != nil || !certificate.IsCA || now.Before(certificate.NotBefore) || !now.Before(certificate.NotAfter) {
			return errors.New("trust bundle contains an invalid or expired CA")
		}
		roots.AddCert(certificate)
		ca = rest
	}
	keys := 0
	for remaining := identity; len(bytes.TrimSpace(remaining)) > 0; {
		block, rest := pem.Decode(remaining)
		if block == nil || len(block.Headers) != 0 {
			return errors.New("identity bundle must be unencrypted PEM")
		}
		switch block.Type {
		case "CERTIFICATE":
		case "PRIVATE KEY", "RSA PRIVATE KEY", "EC PRIVATE KEY":
			keys++
		default:
			return errors.New("unexpected identity PEM block")
		}
		remaining = rest
	}
	if keys != 1 {
		return errors.New("identity bundle must contain exactly one private key")
	}
	pair, err := tls.X509KeyPair(identity, identity)
	if err != nil {
		return errors.New("identity certificate and private key do not form a valid pair")
	}
	leaf, err := x509.ParseCertificate(pair.Certificate[0])
	if err != nil {
		return errors.New("invalid identity certificate")
	}
	intermediates := x509.NewCertPool()
	for _, der := range pair.Certificate[1:] {
		certificate, err := x509.ParseCertificate(der)
		if err != nil {
			return errors.New("invalid identity certificate chain")
		}
		intermediates.AddCert(certificate)
	}
	options := x509.VerifyOptions{Roots: roots, Intermediates: intermediates, CurrentTime: now, KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth}}
	if config.Endpoint == "repository" {
		options.DNSName = config.Name
		options.KeyUsages = []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}
	} else if leaf.Subject.CommonName != config.Name {
		return errors.New("client certificate CN differs from the authorized identity")
	}
	if leaf.IsCA {
		return errors.New("endpoint identity must not be a CA")
	}
	if _, err := leaf.Verify(options); err != nil {
		return errors.New("identity certificate trust, validity or usage check failed")
	}
	return nil
}
