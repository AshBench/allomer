---
sidebar_position: 2
---

# Publishing the docs

The site uses [Docusaurus](https://docusaurus.io/). It reads the Markdown files in `docs/`. Site configuration and the dependency lock file live in `website/`.

## Preview locally

Use Node.js 22 or later. From the repository root:

```sh
cd website
npm ci
npm start
```

For a production build and local preview:

```sh
npm run build
npm run serve
```

The static site is generated in `website/build/`. Builds fail on broken internal links. Mermaid diagrams are enabled.

The site has a local search index. Search terms and page contents stay in the browser. The index is rebuilt with the site, so no hosted search account or crawler is required. The standard Docusaurus light and dark modes are enabled and follow the visitor's system setting on first use.

## Publish to GitHub Pages

Changes to the docs, website, or Pages workflow publish automatically after they
reach `main`. A maintainer can also start a deployment manually.

1. Push the project to the GitHub repository that will host the docs.
2. In the repository, open **Settings → Pages**. Set the source to **GitHub Actions**.
3. Open **Actions → Publish documentation → Run workflow** on the default branch
   when an immediate manual deployment is needed.
4. Open the site link in the completed deployment job.

The workflow reads the site's address from GitHub Pages. It supports a project path, an account site, or a configured custom domain. It uploads only the generated docs. It does not upload local app samples or research files.

Pull requests run a build check. They do not publish the site. Public contributors
cannot publish from a pull request. The deployment uses GitHub's workflow token,
so no personal access token is needed. To require your approval from every
maintainer, add your account as a required reviewer for the existing
`github-pages` environment.

To check a project path locally:

```sh
DOCS_URL=https://example.github.io DOCS_BASE_URL=/allomer/ npm run build
npm run serve
```

Keep current behavior separate from planned features. Update the docs when an implementation or a tested limitation changes.

The setup follows the [Docusaurus deployment guide](https://docusaurus.io/docs/deployment) and GitHub's [Pages configuration action](https://github.com/actions/configure-pages).
