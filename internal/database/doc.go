// Package database owns the selected host's release metadata and restart boundary.
// It requires recovery evidence before deployment and restores only metadata;
// data restoration and release compensation remain caller-owned decisions.
package database
