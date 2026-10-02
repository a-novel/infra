# Database host startup assets

`startup.sh` serves the new service-owned foundation, including its native systemd lifecycle.

`legacy-startup.sh` serves the existing shared-foundation hosts. Even comment changes replace its
immutable instance templates, so edits require explicit host-maintenance approval. Foundation
mocked plans check its reviewed digest for both databases, with and without project onboarding.

Both ownership probes use `stat -c`, supported by GNU and BusyBox database images. Applying a
legacy-script fix requires a separately reviewed foundation maintenance plan before retrying a
release; merging the code alone does not update an existing host.

Both paths use `shutdown.sh`.
