package submission

// authenticationParameters keeps optional waitlist access paired with its endpoint.
// These are configuration selectors; authorization comes from protected custody.
func authenticationParameters(parameters map[string]string) map[string]string {
	patterns := map[string]string{
		"jsonKeysHost":        `agora-json-keys-grpc-[a-z0-9-]+\.(a|[a-z]+-[a-z]+[1-9][0-9]*)\.run\.app`,
		"platformAuthURL":     `(https://[^\s"\\]+)?`,
		"smtpAddress":         `[a-zA-Z0-9.-]+:[1-9][0-9]{0,4}`,
		"smtpUsername":        `[^\r\n\x00]{1,512}`,
		"smtpSenderDomain":    `[a-zA-Z0-9.-]+`,
		"smtpSenderEmail":     `[^\s@]+@[^\s@]+`,
		"smtpSenderName":      `[^\r\n\x00]{1,512}`,
		"smtpPasswordVersion": `[1-9][0-9]*`,
	}
	if _, enabled := parameters["waitlistSecretVersion"]; enabled {
		patterns["waitlistURL"] = `https://[^\s"\\]+`
		patterns["waitlistSecretVersion"] = `[1-9][0-9]*`
	}
	return patterns
}
