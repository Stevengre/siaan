"use strict";

function normalizeLogin(value) {
  return String(value ?? "")
    .trim()
    .replace(/^@+/, "")
    .toLowerCase();
}

function parseAllowlist(value) {
  return [...new Set(String(value ?? "").split(",").map(normalizeLogin).filter(Boolean))].sort();
}

function normalizeIssueRestriction(value) {
  return String(value ?? "").trim().toLowerCase();
}

function shouldEnforceRestriction(value) {
  return normalizeIssueRestriction(value) !== "disabled";
}

module.exports = {
  normalizeIssueRestriction,
  normalizeLogin,
  parseAllowlist,
  shouldEnforceRestriction,
};

if (require.main === module) {
  const [, , issueRestriction, author, maintainers] = process.argv;
  const allowlist = parseAllowlist(maintainers);
  const normalizedAuthor = normalizeLogin(author);

  process.stdout.write(
    JSON.stringify({
      allowlist,
      author: normalizedAuthor,
      authorAllowed: allowlist.includes(normalizedAuthor),
      issueRestriction: normalizeIssueRestriction(issueRestriction),
      shouldEnforceRestriction: shouldEnforceRestriction(issueRestriction),
    }),
  );
}
