// Package recovery constrains a one-shot pgBackRest restore to an approved database
// and backup set. It restores files only; PostgreSQL startup and cutover have separate owners.
package recovery
