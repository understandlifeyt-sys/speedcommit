# speedcommit

Commits incrementing numbers to a GitHub repo as fast as possible.

## Deploy on Railway

1. Push this repo to GitHub
2. Create a new Railway project and connect your repo
3. Add these environment variables in Railway:
   - `GITHUB_USER` - your GitHub username
   - `GITHUB_TOKEN` - your GitHub PAT (needs `repo` scope)
   - `REPO_NAME` - repo to commit to (default: `speed-commit`)
4. Deploy!
