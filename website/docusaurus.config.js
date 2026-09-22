const repository = process.env.GITHUB_REPOSITORY;

/** @type {import('@docusaurus/types').Config} */
module.exports = {
  title: 'Allomer',
  tagline: 'Same content. Another form.',
  url: process.env.DOCS_URL || 'https://allomer.ashbench.com',
  baseUrl: process.env.DOCS_BASE_URL || '/',
  favicon: 'img/allomer-app-icon.png',
  trailingSlash: true,
  onBrokenLinks: 'throw',
  markdown: {mermaid: true, hooks: {onBrokenMarkdownLinks: 'throw'}},
  themes: [
    '@docusaurus/theme-mermaid',
    [require.resolve('@easyops-cn/docusaurus-search-local'), {
      docsDir: '../docs',
      docsRouteBasePath: '/',
      indexDocs: true,
      indexBlog: false,
      indexPages: false,
      hashed: 'filename',
      highlightSearchTermsOnTargetPage: true,
      explicitSearchResultPath: true,
    }],
  ],
  presets: [['classic', {
    docs: {
      path: '../docs',
      routeBasePath: '/',
      sidebarPath: './sidebars.js',
      ...(repository ? {editUrl: `https://github.com/${repository}/edit/main/`} : {}),
    },
    blog: false,
    theme: {customCss: './src/css/custom.css'},
  }]],
  themeConfig: {
    image: 'img/allomer-app-icon.png',
    metadata: [
      {name: 'description', content: 'Local file conversion for Apple Silicon Macs.'},
      {name: 'theme-color', content: '#171b36'},
    ],
    navbar: {
      title: 'Allomer',
      logo: {alt: 'Allomer', src: 'img/allomer-mark.svg', srcDark: 'img/allomer-mark-dark.svg'},
      items: [
        {to: '/getting-started/', label: 'Get started', position: 'left'},
        {
          type: 'dropdown',
          label: 'Use Allomer',
          position: 'left',
          items: [
            {label: 'Automatic conversion', to: '/automatic/'},
            {label: 'Manual conversion', to: '/getting-started/#convert-one-file'},
            {label: 'Command line', to: '/getting-started/#use-the-command-line'},
            {label: 'Backups and Undo', to: '/automatic/#originals-and-undo'},
          ],
        },
        {
          type: 'dropdown',
          label: 'Formats',
          position: 'left',
          items: [
            {label: 'All formats', to: '/formats/'},
            {label: 'Images and artwork', to: '/images/'},
            {label: 'Documents and text', to: '/documents/'},
            {label: 'Audio', to: '/audio/'},
            {label: 'Video', to: '/video/'},
          ],
        },
        {
          type: 'dropdown',
          label: 'Develop',
          position: 'left',
          items: [
            {label: 'Project status', to: '/project-status/'},
            {label: 'Architecture', to: '/architecture/'},
            {label: 'Dependencies', to: '/dependencies/'},
            {label: 'Release process', to: '/release/'},
            {label: 'Publish the docs', to: '/publishing/'},
          ],
        },
        {type: 'search', position: 'right'},
        ...(repository ? [{href: `https://github.com/${repository}`, label: 'Source', position: 'right'}] : []),
      ],
    },
    colorMode: {
      defaultMode: 'light',
      disableSwitch: false,
      respectPrefersColorScheme: true,
    },
    footer: {
      style: 'dark',
      links: [
        {
          title: 'Use Allomer',
          items: [
            {label: 'Get started', to: '/getting-started/'},
            {label: 'Automatic conversion', to: '/automatic/'},
            {label: 'Format directory', to: '/formats/'},
          ],
        },
        {
          title: 'Formats',
          items: [
            {label: 'Images', to: '/images/'},
            {label: 'Documents', to: '/documents/'},
            {label: 'Audio and video', to: '/video/'},
            {label: 'Data and archives', to: '/configuration/'},
          ],
        },
        {
          title: 'Project',
          items: [
            {label: 'Project status', to: '/project-status/'},
            {label: 'Architecture', to: '/architecture/'},
            {label: 'Release process', to: '/release/'},
            ...(repository ? [{label: 'Source', href: `https://github.com/${repository}`}] : []),
          ],
        },
      ],
      copyright: `Copyright © ${new Date().getFullYear()} AshBench contributors. Allomer is in development.`,
    },
  },
};
