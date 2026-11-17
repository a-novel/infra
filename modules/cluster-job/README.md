# cluster-job

Runs one Job, which the apply waits on, or a CronJob when the caller sets a schedule. Both run the
same pods, which Pod Security's restricted level admits, and never retry a failed one. The container
can trust its database's CA or the services CA, carry a service token, and write to a small `/tmp`
in memory. The cluster root's checks, migrations and scheduled jobs call it, and so does the
recovery drill's check.
