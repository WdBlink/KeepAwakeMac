export const meta = {
  name: "keepawakemac-release-review",
  description: "Read-only source and bilingual documentation review before a source prerelease.",
}

const schema = {
  type: "object",
  additionalProperties: false,
  required: ["ready", "findings", "limitations"],
  properties: {
    ready: { type: "boolean" },
    findings: {
      type: "array", maxItems: 8,
      items: {
        type: "object", additionalProperties: false,
        required: ["severity", "file", "line", "problem", "fix"],
        properties: {
          severity: { type: "string", enum: ["P0", "P1", "P2"] },
          file: { type: "string", maxLength: 160 },
          line: { type: "integer" },
          problem: { type: "string", maxLength: 700 },
          fix: { type: "string", maxLength: 500 },
        },
      },
    },
    limitations: { type: "array", maxItems: 6, items: { type: "string", maxLength: 400 } },
  },
}

const common = `Review KeepAwakeMac in the current workspace for a SOURCE-ONLY prerelease.
The user authorized source cleanup, complete Chinese and English READMEs, and release
only after material issues are resolved. Read actual current files, including existing
uncommitted changes. Do not edit files, run power operations, register services, launch
the application, access private agent sessions, or publish anything. Existing simulated
test/build logs are under build/Validation/release-*.log. Do not claim physical tests or
Developer ID notarization passed. Report only actionable factual defects, not style
preferences; cite a verified file and line for each finding. ready=false if findings
contain a defect that must be fixed before this source prerelease. Reply in Chinese.`

const [source, docs] = await parallel([
  () => agent(`${common}
Review App/, Helper/, Shared/, Tests/, scripts/, project.yml and CI. Trace lifecycle,
helper registration, switch ordering, error recovery, trust boundaries, and packaging.
Check the existing modifications rather than reverting them. Focus on concrete bugs
and missing regression coverage for risky behavior. Read code; do not rerun tests.`, {
    id: "source", sandbox: "read-only", timeoutMs: 300000, retries: 0, schema,
  }),
  () => agent(`${common}
Review README.md, README.en.md, docs/DEVELOPMENT.md, RELEASE_CHECKLIST.md,
docs/releases/v0.1.0.md, and SECURITY.md against implementation and build evidence.
Check bilingual parity, all user features and stop conditions, first launch/permissions,
upgrades/uninstall, agent task limits, mode interactions, privacy, source build commands,
links, release scope and stale screenshots/claims. Documentation is bilingual; app UI
is still Chinese. Do not confuse README translation with application localization.`, {
    id: "docs", sandbox: "read-only", timeoutMs: 300000, retries: 0, schema,
  }),
], { concurrency: 2, label: "release-review" })

return { approved: source.ready && docs.ready, source, docs }
