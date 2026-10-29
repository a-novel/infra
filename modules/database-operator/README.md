# database-operator

Installs cert-manager, CloudNativePG and its Barman Cloud plugin from their charts, each image pulled
from the caller's registry. The production cluster and the recovery drill both call it, so a drill
restores under the operator production runs.
