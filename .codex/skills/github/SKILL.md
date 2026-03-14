---
name: github
description: |
  Use Symphony's `github_graphql` client tool for raw GitHub GraphQL
  operations such as issue reads, comments, and label transitions.
---

# GitHub GraphQL

Use this skill for raw GitHub GraphQL work during Symphony app-server sessions.

## Primary tool

Use the `github_graphql` client tool exposed by Symphony's app-server session.
It reuses Symphony's configured GitHub auth for the session.

Tool input:

```json
{
  "query": "query or mutation document",
  "variables": {
    "optional": "graphql variables object"
  }
}
```

Tool behavior:

- Send one GraphQL operation per tool call.
- Treat a top-level `errors` array as a failed GraphQL operation even if the tool call itself completed.
- Keep operations narrowly scoped; ask only for fields required by the task.

## Common workflows

### Query an issue by number

```graphql
query IssueByNumber($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    issue(number: $number) {
      id
      number
      title
      body
      state
      url
      labels(first: 20) {
        nodes {
          name
        }
      }
      assignees(first: 10) {
        nodes {
          login
        }
      }
    }
  }
}
```

### Add a comment to an issue

```graphql
mutation AddIssueComment($issueId: ID!, $body: String!) {
  addComment(input: {subjectId: $issueId, body: $body}) {
    commentEdge {
      node {
        id
        url
      }
    }
  }
}
```

### Set status labels on an issue

Resolve label IDs first:

```graphql
query RepoLabels($owner: String!, $repo: String!, $query: String!) {
  repository(owner: $owner, name: $repo) {
    labels(first: 20, query: $query) {
      nodes {
        id
        name
      }
    }
  }
}
```

Then update labels:

```graphql
mutation ReplaceIssueLabels($issueId: ID!, $labelIds: [ID!]!) {
  clearLabelsFromLabelable(input: {labelableId: $issueId}) {
    clientMutationId
  }
  addLabelsToLabelable(input: {labelableId: $issueId, labelIds: $labelIds}) {
    clientMutationId
  }
}
```
