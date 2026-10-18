// Release versions, vX.Y.Z: the only tags a release pins or deploys.
export const semver = String.raw`v\d+\.\d+\.\d+`;

export const isRelease = (version) => new RegExp(`^${semver}$`).test(version);

/** The newest of the release versions given, ignoring empty ones; "" when none. */
export function newest(...versions) {
  const parts = (version) => version.slice(1).split(".").map(Number);
  const later = (a, b) => {
    const [x, y] = [parts(a), parts(b)];
    const index = x.findIndex((part, i) => part !== y[i]);
    return index >= 0 && x[index] > y[index];
  };
  return versions
    .filter(Boolean)
    .reduce(
      (best, version) => (!best || later(version, best) ? version : best),
      "",
    );
}
