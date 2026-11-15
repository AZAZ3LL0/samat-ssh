// Package auth owns the agent's identity and credentials: the TLS certificate,
// pairing codes and device tokens.
package auth

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/pem"
	"errors"
	"fmt"
	"math/big"
	"os"
	"path/filepath"
	"time"
)

const (
	certFile = "cert.pem"
	keyFile  = "key.pem"
	// The app pins the key, not the validity period, so the certificate only
	// has to outlive the installation.
	certLifetime = 10 * 365 * 24 * time.Hour
)

// LoadOrCreateCert returns the agent certificate from dir, generating a
// self-signed ECDSA P-256 one on first use. Regenerating it would break every
// paired device, so an existing pair is never replaced.
func LoadOrCreateCert(dir, hostname string, now time.Time) (tls.Certificate, error) {
	certPath := filepath.Join(dir, certFile)
	keyPath := filepath.Join(dir, keyFile)

	cert, err := tls.LoadX509KeyPair(certPath, keyPath)
	if err == nil {
		return cert, nil
	}
	if !errors.Is(err, os.ErrNotExist) {
		return tls.Certificate{}, fmt.Errorf("load certificate from %s: %w", dir, err)
	}

	certPEM, keyPEM, err := generateCert(hostname, now)
	if err != nil {
		return tls.Certificate{}, err
	}
	// The agent and `pulse-agent pair` may both start on a fresh install. Each
	// builds its pair in a private directory and renames it into place: the
	// rename is atomic and fails once dir holds a pair, so exactly one wins and
	// both then load the same files. Writing into dir directly let each side
	// serve or print a different key.
	if err := os.MkdirAll(filepath.Dir(dir), 0o700); err != nil {
		return tls.Certificate{}, fmt.Errorf("create %s: %w", filepath.Dir(dir), err)
	}
	staging, err := os.MkdirTemp(filepath.Dir(dir), filepath.Base(dir)+".tmp-")
	if err != nil {
		return tls.Certificate{}, fmt.Errorf("create staging directory: %w", err)
	}
	defer func() { _ = os.RemoveAll(staging) }()
	if err := os.WriteFile(filepath.Join(staging, keyFile), keyPEM, 0o600); err != nil {
		return tls.Certificate{}, fmt.Errorf("write key: %w", err)
	}
	if err := os.WriteFile(filepath.Join(staging, certFile), certPEM, 0o600); err != nil {
		return tls.Certificate{}, fmt.Errorf("write certificate: %w", err)
	}
	renameErr := os.Rename(staging, dir)
	cert, err = tls.LoadX509KeyPair(certPath, keyPath)
	if err != nil {
		return tls.Certificate{}, fmt.Errorf("load certificate from %s: %w", dir, errors.Join(err, renameErr))
	}
	return cert, nil
}

func generateCert(hostname string, now time.Time) (certPEM, keyPEM []byte, err error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, nil, fmt.Errorf("generate key: %w", err)
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 127))
	if err != nil {
		return nil, nil, fmt.Errorf("generate serial: %w", err)
	}
	template := &x509.Certificate{
		SerialNumber:          serial,
		Subject:               pkix.Name{CommonName: "pulse-agent"},
		DNSNames:              []string{hostname},
		NotBefore:             now.Add(-time.Hour),
		NotAfter:              now.Add(certLifetime),
		KeyUsage:              x509.KeyUsageDigitalSignature,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		return nil, nil, fmt.Errorf("create certificate: %w", err)
	}
	keyDER, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		return nil, nil, fmt.Errorf("marshal key: %w", err)
	}
	certPEM = pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	keyPEM = pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: keyDER})
	return certPEM, keyPEM, nil
}

// Fingerprint returns the value the app pins: SHA-256 of the certificate's
// SubjectPublicKeyInfo, base64url without padding.
func Fingerprint(cert tls.Certificate) (string, error) {
	if len(cert.Certificate) == 0 {
		return "", errors.New("certificate chain is empty")
	}
	leaf, err := x509.ParseCertificate(cert.Certificate[0])
	if err != nil {
		return "", fmt.Errorf("parse certificate: %w", err)
	}
	sum := sha256.Sum256(leaf.RawSubjectPublicKeyInfo)
	return base64.RawURLEncoding.EncodeToString(sum[:]), nil
}
