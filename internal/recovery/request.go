package recovery

import (
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"time"
)

// Request is the private, reviewed selection supplied to a disposable recovery host.
// Its database identity must come from independent source evidence, not the catalog being checked.
type Request struct {
	// Service owns both the stanza and repository prefix. The pilot supports JSON Keys.
	Service string `json:"service"`
	// SourceProject owns the original database, outside the disposable target.
	SourceProject string `json:"source_project"`
	// Project is the independently approved disposable project.
	Project string `json:"project"`
	// ManagementProject owns the recovery identity and native backup bucket.
	ManagementProject string `json:"management_project"`
	// ManagementNumber binds the bucket to its registered management project.
	ManagementNumber string `json:"management_number"`
	// SystemID is PostgreSQL's decimal system identifier, kept losslessly as text.
	SystemID string `json:"system_id"`
	// Major is the PostgreSQL major accepted for this restore image.
	Major int `json:"major"`
	// Set is one completed native full or differential backup label, never latest.
	Set string `json:"set"`
	// RepositoryTime preserves an optional RFC3339 historical repository view.
	RepositoryTime string `json:"repository_time,omitempty"`
}

// Validate limits the pilot to exact-set recovery to backup consistency, without promotion.
func (r Request) Validate() error {
	for _, project := range []string{r.SourceProject, r.Project, r.ManagementProject} {
		if !matches(`[a-z][a-z0-9-]{4,28}[a-z0-9]`, project) {
			return errors.New("invalid recovery project")
		}
	}
	if r.Service != "json-keys" || r.Major != 18 {
		return errors.New("recovery requires the JSON Keys PostgreSQL 18 image")
	}
	if r.Project == r.SourceProject || r.Project == r.ManagementProject || !matches(`a-novel-recovery-[a-z0-9-]+`, r.Project) {
		return errors.New("recovery requires an independent disposable project")
	}
	if !matches(`[1-9][0-9]{0,19}`, r.SystemID) || !matches(`[1-9][0-9]{5,19}`, r.ManagementNumber) {
		return errors.New("invalid database or management identity")
	}
	if !matches(`[0-9]{8}-[0-9]{6}F(?:_[0-9]{8}-[0-9]{6}D)?`, r.Set) {
		return errors.New("select an exact full or differential backup")
	}
	if r.RepositoryTime != "" {
		if _, err := time.Parse(time.RFC3339, r.RepositoryTime); err != nil {
			return errors.New("invalid repository time")
		}
	}
	return nil
}

// Identity is the separately enabled management-owned recovery account.
func (r Request) Identity() string {
	return "pgbr-json-keys-recovery@" + r.ManagementProject + ".iam.gserviceaccount.com"
}

// Arguments keeps native configuration explicit and independent of inherited config files.
func (r Request) Arguments() []string {
	args := []string{
		"--no-config", "--stanza=" + r.Service, "--repo=1", "--repo1-type=gcs",
		"--repo1-path=/" + r.Service, "--repo1-gcs-key-type=auto",
		"--repo1-gcs-bucket=" + r.ManagementProject + "-" + r.ManagementNumber + "-pgbr-" + r.Service,
		"--log-level-file=off", "--log-level-console=info", "--io-timeout=10",
	}
	if r.RepositoryTime != "" {
		args = append(args, "--repo-target-time="+r.RepositoryTime)
	}
	return args
}

// CheckCatalog verifies selection, not payload availability. pgBackRest owns dependency checks.
func (r Request) CheckCatalog(data []byte) error {
	var stanzas []struct {
		Name   string
		Status struct{ Code *int }
		DB     []struct {
			ID       int
			RepoKey  int         `json:"repo-key"`
			SystemID json.Number `json:"system-id"`
			Version  string
		}
		Backup []struct {
			Label    string
			Error    *bool
			Database struct {
				ID      int
				RepoKey int `json:"repo-key"`
			}
		}
	}
	if json.Unmarshal(data, &stanzas) != nil || len(stanzas) != 1 {
		return errors.New("invalid native catalog")
	}
	stanza := stanzas[0]
	if stanza.Name != r.Service || stanza.Status.Code == nil || *stanza.Status.Code != 0 {
		return errors.New("native catalog is not healthy for the selected service")
	}
	matches := 0
	for _, backup := range stanza.Backup {
		if backup.Label != r.Set || backup.Error == nil || *backup.Error || backup.Database.RepoKey != 1 {
			continue
		}
		for _, database := range stanza.DB {
			if database.ID != backup.Database.ID || database.RepoKey != 1 {
				continue
			}
			if string(database.SystemID) == r.SystemID && database.Version == fmt.Sprint(r.Major) {
				matches++
			}
		}
	}
	if matches != 1 {
		return errors.New("exact backup does not identify the approved database")
	}
	return nil
}

func matches(pattern, value string) bool {
	return regexp.MustCompile("^(?:" + pattern + ")$").MatchString(value)
}
