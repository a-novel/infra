# Database host startup assets

`startup.sh` serves the new service-owned foundation, including its native systemd lifecycle.

`legacy-startup.sh` preserves the startup bytes from the last applied shared-foundation revision
`98739bbba8bff969658c2b186b5233393c18e1fe`. Even comment changes replace its immutable instance
templates. Keep this compatibility copy frozen until the legacy hosts are retired; any earlier
change requires explicit host-maintenance approval. Foundation mocked plans check its digest for
both databases, with and without project onboarding.

Both paths use `shutdown.sh`.
