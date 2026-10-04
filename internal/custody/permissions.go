package custody

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"strings"
	"time"

	"google.golang.org/api/googleapi"
	"google.golang.org/api/option"
	"google.golang.org/api/storage/v1"
)

// checkPermissions exercises only run-specific synthetic objects. Interrupted state
// probes remain visible to the foundation inventory and require reconciliation.
func (custody store) checkPermissions(args []string, getenv func(string) string, output io.Writer, options []option.ClientOption) (result error) {
	if len(args) != 2 {
		return failure{64, "Usage: infra custody permissions check <state-bucket> <own-scope> <peer-scope>"}
	}
	own, peer := args[0], args[1]
	sequence := getenv("GITHUB_RUN_ID") + "-" + getenv("GITHUB_RUN_ATTEMPT")
	commit := getenv("GITHUB_SHA")
	if !foundationScopePattern.MatchString(own) || !foundationScopePattern.MatchString(peer) ||
		!sequencePattern.MatchString(sequence) || !commitPattern.MatchString(commit) ||
		!strings.HasSuffix(custody.bucket, "-tofu-state") {
		return failure{65, "Invalid synthetic permission-check scope or run identity."}
	}
	parts, peerParts := strings.Split(own, "/"), strings.Split(peer, "/")
	if parts[4] == peerParts[4] ||
		getenv("GITHUB_REPOSITORY") != "a-novel/infra" || getenv("GITHUB_REF") != "refs/heads/master" ||
		getenv("GITHUB_EVENT_NAME") != "workflow_dispatch" || getenv("RELEASE_ACTION") != "check-release-permissions" ||
		getenv("GITHUB_WORKFLOW_REF") != "a-novel/infra/.github/workflows/release.yaml@refs/heads/master" ||
		getenv("PERMISSION_CHECK_ENVIRONMENT") != "production-"+parts[4]+"-"+parts[2]+"-release" {
		return failure{77, "Permission checks require the selected protected master release environment."}
	}
	ctx, cancel := context.WithTimeout(custody.ctx, 2*time.Minute)
	defer cancel()
	client, err := storage.NewService(ctx, append(options, option.WithScopes(storage.DevstorageReadWriteScope))...)
	if err != nil {
		return failure{70, "Permission-check client unavailable."}
	}
	receipts := strings.TrimSuffix(custody.bucket, "-tofu-state") + "-deployment-receipts"
	probe := "/permission-checks/" + commit + "/" + sequence + "/probe.json"
	stateName, receiptName := own+"/release"+probe, own+"/production"+probe
	data := []byte(`{"kind":"synthetic-permission-check"}`)
	if _, err := fmt.Fprintf(output, "Synthetic state: gs://%s/%s\nRetained synthetic receipt: gs://%s/%s\n", custody.bucket, stateName, receipts, receiptName); err != nil {
		return err
	}
	insert := func(bucket, name string, generation int64) (*storage.Object, error) {
		return client.Objects.Insert(bucket, &storage.Object{Name: name}).
			Media(bytes.NewReader(data), googleapi.ContentType("application/json"), googleapi.ChunkSize(0)).
			IfGenerationMatch(generation).Fields("bucket,name,generation").Context(ctx).Do()
	}
	var temporary []objectReference
	defer func() {
		cleanup, stop := context.WithTimeout(context.WithoutCancel(custody.ctx), time.Minute)
		defer stop()
		for _, ref := range temporary {
			if err := client.Objects.Delete(ref.Bucket, ref.Name).Generation(ref.Generation).
				IfGenerationMatch(ref.Generation).Context(cleanup).Do(); err != nil {
				result = failure{70, "Synthetic state cleanup unconfirmed; reconcile the printed probe path before planning or retrying."}
			}
		}
	}()
	// A receipt probe is an input to this check, never a deployment-success record.
	for _, target := range []struct{ bucket, name string }{{custody.bucket, stateName}, {receipts, receiptName}} {
		ref, err := createObject(ctx, client, target.bucket, target.name, data)
		if err != nil {
			return failure{70, "Synthetic creation unconfirmed; inspect the printed paths before retrying."}
		}
		if target.bucket == custody.bucket {
			temporary = append(temporary, ref)
		}
		if _, err := fmt.Fprintf(output, "Acknowledged synthetic generation: %s %d\n", target.name, ref.Generation); err != nil {
			return err
		}
		actual, err := readObject(ctx, client, ref)
		if err != nil || !bytes.Equal(actual, data) {
			return failure{70, "Synthetic readback did not match the acknowledged generation."}
		}
		updated, err := insert(ref.Bucket, ref.Name, ref.Generation)
		if target.bucket == custody.bucket {
			if err != nil || updated == nil || updated.Bucket != ref.Bucket || updated.Name != ref.Name || updated.Generation <= 0 || updated.Generation == ref.Generation {
				return failure{70, "Synthetic state replacement unconfirmed; reconcile the printed probe path."}
			}
			ref.Generation = updated.Generation
			temporary = append(temporary, ref)
			actual, err = readObject(ctx, client, ref)
			if err != nil || !bytes.Equal(actual, data) {
				return failure{70, "Synthetic state replacement readback failed."}
			}
		} else {
			if !permissionDenied(err, "storage.objects.delete") {
				return failure{70, "Receipt overwrite did not return the expected IAM denial; inspect the synthetic receipt."}
			}
			err = client.Objects.Delete(ref.Bucket, ref.Name).Generation(ref.Generation).
				IfGenerationMatch(ref.Generation).Context(ctx).Do()
			if !permissionDenied(err, "storage.objects.delete") {
				return failure{70, "Receipt deletion did not return the expected IAM denial; inspect the synthetic receipt."}
			}
			generation, err := liveGeneration(ctx, client, ref.Bucket, ref.Name)
			if err != nil || generation != ref.Generation {
				return failure{70, "Synthetic receipt changed during the immutability checks."}
			}
		}
	}
	// IAM must deny these names whether or not the peer's parallel check created them.
	// Metadata-only reads ensure an unexpected grant cannot expose a stored payload.
	for _, target := range []struct{ bucket, name string }{{custody.bucket, peer + "/release" + probe}, {receipts, peer + "/production" + probe}} {
		if _, err := fmt.Fprintf(output, "Synthetic peer target: gs://%s/%s\n", target.bucket, target.name); err != nil {
			return err
		}
		_, err := client.Objects.Get(target.bucket, target.name).Fields("generation").Context(ctx).Do()
		if !permissionDenied(err, "storage.objects.get") {
			return failure{70, "Peer metadata read did not return the expected IAM denial."}
		}
		_, err = insert(target.bucket, target.name, 0)
		if !permissionDenied(err, "storage.objects.create") {
			return failure{70, "Peer creation did not return the expected IAM denial; reconcile this run's synthetic peer path."}
		}
	}
	return nil
}

// permissionDenied excludes authentication, retention, precondition and transport failures.
func permissionDenied(err error, permission string) bool {
	var remote *googleapi.Error
	return errors.As(err, &remote) && remote.Code == 403 &&
		(strings.Contains(remote.Message, "does not have "+permission+" access") ||
			strings.Contains(remote.Message, "Permission '"+permission+"' denied"))
}
