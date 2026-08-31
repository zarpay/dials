import { defineConfig } from 'vitepress';

export default defineConfig({
  base: '/dials/',
  title: 'dials',
  description: 'Operator-adjustable values with per-variant overrides for Ruby and Rails',
  lang: 'en-US',
  cleanUrls: true,
  lastUpdated: true,
  // README.md documents this directory for GitHub browsing; it is not a page.
  srcExclude: ['README.md'],
  appearance: false,
  vite: {
    server: {
      allowedHosts: true,
    },
  },
  themeConfig: {
    siteTitle: 'dials',
    search: {
      provider: 'local',
    },
    nav: [
      { text: 'Home', link: '/' },
      { text: 'Quick Start', link: '/getting-started/' },
      { text: 'Concepts', link: '/concepts/the-dial-model' },
      { text: 'Guides', link: '/guides/install' },
      { text: 'Design', link: '/design/decisions' },
      { text: 'Reference', link: '/reference/api' },
    ],
    sidebar: [
      {
        text: 'Introduction',
        items: [
          { text: 'Home', link: '/' },
          { text: 'Quick Start', link: '/getting-started/' },
        ],
      },
      {
        text: 'Concepts',
        items: [
          { text: 'The Dial Model', link: '/concepts/the-dial-model' },
          { text: 'Variants and Scopes', link: '/concepts/variants-and-scopes' },
          { text: 'Caching', link: '/concepts/caching' },
          { text: 'The Change Log', link: '/concepts/change-log' },
          { text: 'When NOT to Use a Dial', link: '/concepts/pattern-boundary' },
        ],
      },
      {
        text: 'Guides',
        items: [
          { text: 'Install (New Apps)', link: '/guides/install' },
          { text: 'Retrofit a Constant', link: '/guides/retrofit-a-constant' },
          { text: 'Retrofit an Admin Table', link: '/guides/retrofit-an-admin-table' },
          { text: 'Build a Write Surface', link: '/guides/build-a-write-surface' },
          { text: 'Testing with Dials', link: '/guides/testing' },
        ],
      },
      {
        text: 'Design',
        items: [
          { text: 'Design Decisions', link: '/design/decisions' },
          { text: 'Compared to Alternatives', link: '/design/comparisons' },
          { text: 'Possible Enhancements', link: '/design/possible-enhancements' },
        ],
      },
      {
        text: 'Reference',
        items: [
          { text: 'API Reference', link: '/reference/api' },
        ],
      },
    ],
    socialLinks: [{ icon: 'github', link: 'https://github.com/zarpay/dials' }],
    outline: {
      level: [2, 3],
      label: 'On this page',
    },
    docFooter: {
      prev: 'Previous page',
      next: 'Next page',
    },
    footer: {
      message: 'Constants you can turn without a deploy.',
      copyright: 'Released under the MIT License',
    },
  },
});
