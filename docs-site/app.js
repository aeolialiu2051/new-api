const sectionsByLocale = {
  zh: [
    { title: '开始使用', links: [['文档总览','/docs'],['快速开始','/docs/quickstart'],['充值与账单','/docs/billing']] },
    { title: 'Codex', links: [['概览','/docs/codex'],['安装指南','/docs/codex/install'],['配置教程','/docs/codex/config']] },
    { title: '开发者', links: [['API 参考','/docs/api'],['OpenAI 兼容接口','/docs/api/openai'],['常见问题','/docs/faq']] }
  ],
  en: [
    { title: 'Get started', links: [['Documentation','/docs'],['Quickstart','/docs/quickstart'],['Billing','/docs/billing']] },
    { title: 'Codex', links: [['Overview','/docs/codex'],['Installation','/docs/codex/install'],['Configuration','/docs/codex/config']] },
    { title: 'Developers', links: [['API reference','/docs/api'],['OpenAI-compatible API','/docs/api/openai'],['FAQ','/docs/faq']] }
  ]
}

const ui = {
  zh: { docs:'文档', faq:'常见问题', search:'搜索或提问…', searchLabel:'搜索文档', theme:'切换主题', console:'控制台', menu:'打开菜单', sidebar:'文档导航', toc:'本页目录', select:'↑↓ 选择', open:'↵ 打开', noResults:'没有找到相关文档', copy:'复制', copied:'已复制', support:'没有找到答案？请前往', supportLink:'WarpGate API 控制台', supportEnd:'获取支持。', switchLanguage:'Switch to English', language:'EN' },
  en: { docs:'Docs', faq:'FAQ', search:'Search or ask…', searchLabel:'Search documentation', theme:'Toggle theme', console:'Console', menu:'Open menu', sidebar:'Documentation navigation', toc:'On this page', select:'↑↓ Select', open:'↵ Open', noResults:'No matching documentation found', copy:'Copy', copied:'Copied', support:'Still need help? Visit the', supportLink:'WarpGate API Console', supportEnd:'for support.', switchLanguage:'切换到中文', language:'中文' }
}

let currentLocale = localStorage.docsLanguage === 'en' || localStorage.docsLanguage === 'zh' ? localStorage.docsLanguage : (navigator.language.toLowerCase().startsWith('zh') ? 'zh' : 'en')

const cards = items => `<div class="doc-grid">${items.map(([title,desc,path]) => {
  const external = path.startsWith('http')
  return `<a class="doc-card" href="${external ? path : `#${path}`}"${external ? ' target="_blank" rel="noreferrer"' : ''}><strong>${title} <span style="float:right">→</span></strong><span>${desc}</span></a>`
}).join('')}</div>`
const escapeHtml = value => value.replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;')
const languageKeywords = {
  javascript: new Set(['const','let','var','new','import','from','await','async','function','return','true','false','null','undefined']),
  python: new Set(['from','import','as','def','return','if','else','elif','for','while','in','is','not','and','or','True','False','None']),
  shell: new Set(['curl','export'])
}
function highlightCode(value, language = '') {
  language = ({ terminal:'shell', 'config.toml':'toml' })[language.toLowerCase()] || language.toLowerCase()
  const keywords = languageKeywords[language] || new Set()
  const tokenPattern = /(\/\/[^\n]*|#[^\n]*|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`|\b\d+(?:\.\d+)?\b|\b[A-Za-z_$][\w$]*\b)/g
  let output = '', cursor = 0
  for (const match of value.matchAll(tokenPattern)) {
    output += escapeHtml(value.slice(cursor, match.index))
    const token = match[0]
    let className = ''
    if ((language === 'javascript' && token.startsWith('//')) || (language !== 'javascript' && token.startsWith('#'))) className = 'token-comment'
    else if (/^["'`]/.test(token)) className = 'token-string'
    else if (/^\d/.test(token)) className = 'token-number'
    else if (keywords.has(token)) className = 'token-keyword'
    else if (value.slice(match.index + token.length).trimStart().startsWith('(')) className = 'token-function'
    else if (language === 'toml' && value.slice(match.index + token.length).trimStart().startsWith('=')) className = 'token-property'
    output += className ? `<span class="${className}">${escapeHtml(token)}</span>` : escapeHtml(token)
    cursor = match.index + token.length
  }
  return output + escapeHtml(value.slice(cursor))
}
const code = (title, value, language = title.toLowerCase()) => `<div class="code-block"><div class="code-title"><span class="code-language-dot"></span>${title}</div><button class="copy-code" data-copy="${encodeURIComponent(value)}">复制</button><pre><code class="code-content">${highlightCode(value, language)}</code></pre></div>`
const codeTabs = items => `<div class="code-tabs"><div class="code-tab-list" role="tablist">${items.map(([label], index) => `<button class="code-tab${index === 0 ? ' active' : ''}" role="tab" aria-selected="${index === 0}" data-tab="${index}">${label}</button>`).join('')}</div>${items.map(([label,value,language], index) => `<div class="code-tab-panel${index === 0 ? ' active' : ''}" role="tabpanel" data-panel="${index}">${code(label, value, language)}</div>`).join('')}</div>`

const pagesZh = {
  '/docs': { nav:'docs', eyebrow:'文档', title:'文档总览', lead:'WarpGate API 接入文档导航：从创建密钥开始，快速完成 Codex 与 OpenAI 兼容客户端的配置。', body: `
    <p>WarpGate API 为开发者提供统一、稳定的 OpenAI 兼容模型访问入口，并支持 Codex 接入。</p>
    <h2 id="start">快速开始</h2><p>首次使用只需要三个步骤：注册账号、创建 API Key，然后将客户端的 Base URL 指向 WarpGate API。</p>
    ${cards([['创建 API Key','进入控制台创建并妥善保存你的密钥。','/docs/quickstart'],['查看模型','在模型广场确认账号当前可用的模型。','https://warpgateapi.com/pricing']])}
    <h2 id="codex">Codex</h2><p>Codex 使用 OpenAI 兼容接口，Base URL 为 <code>https://warpgateapi.com/v1</code>。</p>
    ${cards([['安装指南','安装 Codex CLI、App 或 IDE 扩展。','/docs/codex/install'],['配置教程','配置 auth.json 与 config.toml。','/docs/codex/config']])}
    <h2 id="api">API 与 SDK</h2><p>现有 OpenAI SDK 通常只需替换 Base URL 与 API Key 即可迁移。</p>
    ${cards([['API 参考','了解鉴权、端点与错误响应。','/docs/api'],['OpenAI 兼容接口','Chat Completions 与 Responses 示例。','/docs/api/openai']])}
    <div class="callout"><strong>接入地址速记</strong><p>Codex / OpenAI 兼容客户端：<code>https://warpgateapi.com/v1</code>。</p></div>` },
  '/docs/quickstart': { nav:'docs', eyebrow:'开始使用', title:'快速开始', lead:'几分钟内创建密钥并发出你的第一个 API 请求。', body: `<ol class="steps"><li><strong>登录控制台</strong>访问 <a href="https://warpgateapi.com">warpgateapi.com</a> 注册或登录账号。</li><li><strong>创建 API Key</strong>打开“令牌”页面，新建一个令牌并复制保存。密钥仅应存储在安全的环境变量中。</li><li><strong>发送测试请求</strong>使用下面的命令验证连接。</li></ol>${code('Terminal',`curl https://warpgateapi.com/v1/chat/completions \\\n  -H "Authorization: Bearer $WARPGATE_API_KEY" \\\n  -H "Content-Type: application/json" \\\n  -d '{"model":"gpt-5.4-mini","messages":[{"role":"user","content":"Hello"}]}'`)}<div class="callout"><strong>模型名称</strong><p>示例模型可能随上游可用性变化，请以控制台模型广场中显示的名称为准。</p></div>` },
  '/docs/billing': { nav:'docs', eyebrow:'开始使用', title:'充值与账单', lead:'了解余额、用量记录与按量计费方式。', body:`<h2 id="balance">账户余额</h2><p>账户余额用于支付 API 调用。充值完成后，可在控制台钱包页面查看余额变化。</p><h2 id="usage">用量记录</h2><p>每次调用的模型、Token 数量、耗时和费用都会记录在“使用日志”中，方便追踪成本。</p><h2 id="pricing">模型定价</h2><p>不同模型的输入、输出和缓存 Token 可能采用不同费率。实际价格以控制台模型广场为准。</p>` },
  '/docs/codex': { nav:'codex', eyebrow:'Codex', title:'Codex 接入指南', lead:'在 Codex CLI、桌面 App 或 IDE 扩展中使用 WarpGate API。', body:`<h2 id="overview">配置概览</h2><p>Codex 使用 OpenAI Responses 兼容接口，Base URL 必须包含 <code>/v1</code>。</p>${code('config.toml',`model_provider = "warpgateapi_proxy"\n\n[model_providers.warpgateapi_proxy]\nname = "WarpGate API"\nbase_url = "https://warpgateapi.com/v1"\nenv_key = "WARPGATE_API_KEY"\nwire_api = "responses"\nrequires_openai_auth = false`)}${cards([['安装 Codex','安装 CLI、App 或编辑器扩展。','/docs/codex/install'],['配置 Codex','添加模型供应商并设置密钥。','/docs/codex/config']])}` },
  '/docs/codex/install': { nav:'codex', eyebrow:'Codex', title:'安装 Codex', lead:'选择 Codex CLI、桌面 App 或 IDE 扩展。', body:`<h2 id="cli">Codex CLI</h2>${code('Terminal','npm install -g @openai/codex\ncodex --version')}<h2 id="app">Codex App</h2><p>安装桌面 App 后，可以和 CLI 共用 <code>~/.codex</code> 下的配置。</p><h2 id="next">下一步</h2><p>继续进行 <a href="#/docs/codex/config">WarpGate API 配置</a>。</p>` },
  '/docs/codex/config': { nav:'codex', eyebrow:'Codex', title:'配置 Codex', lead:'创建供应商配置并通过环境变量安全地提供 API Key。', body:`<h2 id="key">设置密钥</h2>${code('Terminal','export WARPGATE_API_KEY="your-wg-key"')}<h2 id="provider">添加供应商</h2><p>编辑 <code>~/.codex/config.toml</code>：</p>${code('config.toml',`model_provider = "warpgateapi_proxy"\n\n[model_providers.warpgateapi_proxy]\nname = "WarpGate API"\nbase_url = "https://warpgateapi.com/v1"\nenv_key = "WARPGATE_API_KEY"\nwire_api = "responses"\nrequires_openai_auth = false`)}<h2 id="verify">验证</h2>${code('Terminal','codex')}<div class="callout"><strong>Base URL</strong><p>Codex 必须使用 <code>https://warpgateapi.com/v1</code>，并启用 <code>responses</code> wire API。</p></div>` },
  '/docs/api': { nav:'api', eyebrow:'开发者', title:'API 参考', lead:'WarpGate API 提供统一的 OpenAI 兼容端点。', body:`<h2 id="auth">鉴权</h2><p>所有请求均通过 HTTP Bearer Token 鉴权。</p>${code('HTTP','Authorization: Bearer YOUR_API_KEY')}<h2 id="endpoints">端点</h2>${cards([['OpenAI 兼容','/v1/chat/completions 与 /v1/responses。','/docs/api/openai']])}<h2 id="errors">错误响应</h2><p>接口使用标准 HTTP 状态码。请重点处理 <code>401</code> 鉴权失败、<code>429</code> 速率限制与 <code>5xx</code> 上游暂时不可用。</p>` },
  '/docs/api/openai': { nav:'api', eyebrow:'API', title:'OpenAI 兼容接口', lead:'使用现有 OpenAI SDK，只需替换 Base URL 和 API Key。', body:`<h2 id="examples">请求示例</h2><p>选择你使用的语言，以下示例均调用 Responses API。</p>${codeTabs([['JavaScript',`import OpenAI from "openai";\n\nconst client = new OpenAI({\n  apiKey: process.env.WARPGATE_API_KEY,\n  baseURL: "https://warpgateapi.com/v1",\n});\n\nconst response = await client.responses.create({\n  model: "gpt-5.4-mini",\n  input: "Hello",\n});\n\nconsole.log(response.output_text);`,'javascript'],['Python',`import os\nfrom openai import OpenAI\n\nclient = OpenAI(\n    api_key=os.environ["WARPGATE_API_KEY"],\n    base_url="https://warpgateapi.com/v1",\n)\n\nresponse = client.responses.create(\n    model="gpt-5.4-mini",\n    input="Hello",\n)\n\nprint(response.output_text)`,'python'],['curl',`curl https://warpgateapi.com/v1/responses \\\n  -H "Authorization: Bearer $WARPGATE_API_KEY" \\\n  -H "Content-Type: application/json" \\\n  -d '{"model":"gpt-5.4-mini","input":"Hello"}'`,'shell']])}` },
  '/docs/faq': { nav:'faq', eyebrow:'支持', title:'常见问题', lead:'关于地址、鉴权、模型和费用的高频问题。', body:`<h2 id="base-url">Base URL 应该填什么？</h2><p>Codex 和 OpenAI SDK 使用 <code>https://warpgateapi.com/v1</code>。</p><h2 id="unauthorized">为什么返回 401？</h2><p>检查 API Key 是否完整、是否启用，以及请求头是否为 <code>Authorization: Bearer YOUR_API_KEY</code>。</p><h2 id="model">为什么提示模型不存在？</h2><p>模型可用性可能调整，请使用控制台模型广场中展示的准确模型名称。</p><h2 id="rate-limit">遇到 429 怎么办？</h2><p>降低并发、加入指数退避重试，并确认账户余额和令牌额度。</p>` }
}

const pagesEn = {
  '/docs': { nav:'docs', eyebrow:'Documentation', title:'Documentation overview', lead:'Everything you need to connect to WarpGate API, from creating an API key to configuring Codex and OpenAI-compatible clients.', body: `
    <p>WarpGate API gives developers a unified, reliable endpoint for OpenAI-compatible models and Codex.</p>
    <h2 id="start">Get started</h2><p>Start in three steps: create an account, generate an API key, and point your client Base URL to WarpGate API.</p>
    ${cards([['Create an API key','Create and securely save a key in the console.','/docs/quickstart'],['Browse models','See which models are currently available to your account.','https://warpgateapi.com/pricing']])}
    <h2 id="codex">Codex</h2><p>Codex uses the OpenAI-compatible API at <code>https://warpgateapi.com/v1</code>.</p>
    ${cards([['Installation','Install the Codex CLI, App, or IDE extension.','/docs/codex/install'],['Configuration','Configure auth.json and config.toml.','/docs/codex/config']])}
    <h2 id="api">API and SDKs</h2><p>Existing OpenAI SDK integrations usually only need a new Base URL and API key.</p>
    ${cards([['API reference','Learn about authentication, endpoints, and errors.','/docs/api'],['OpenAI-compatible API','Chat Completions and Responses examples.','/docs/api/openai']])}
    <div class="callout"><strong>Base URL</strong><p>For Codex and OpenAI-compatible clients, use <code>https://warpgateapi.com/v1</code>.</p></div>` },
  '/docs/quickstart': { nav:'docs', eyebrow:'Get started', title:'Quickstart', lead:'Create an API key and send your first request in a few minutes.', body: `<ol class="steps"><li><strong>Sign in to the console</strong>Visit <a href="https://warpgateapi.com">warpgateapi.com</a> to create an account or sign in.</li><li><strong>Create an API key</strong>Open the Tokens page, create a token, and save it securely. Store keys only in protected environment variables.</li><li><strong>Send a test request</strong>Run the command below to verify your connection.</li></ol>${code('Terminal',`curl https://warpgateapi.com/v1/chat/completions \\\n+  -H "Authorization: Bearer $WARPGATE_API_KEY" \\\n+  -H "Content-Type: application/json" \\\n+  -d '{"model":"gpt-5.4-mini","messages":[{"role":"user","content":"Hello"}]}'`)}<div class="callout"><strong>Model names</strong><p>Example models may change with upstream availability. Use the exact model name shown in the console.</p></div>` },
  '/docs/billing': { nav:'docs', eyebrow:'Get started', title:'Billing', lead:'Understand balances, usage records, and usage-based pricing.', body:`<h2 id="balance">Account balance</h2><p>Your balance pays for API usage. After adding funds, view balance changes from the console wallet.</p><h2 id="usage">Usage records</h2><p>The usage log records the model, token count, latency, and cost of every request so you can track spending.</p><h2 id="pricing">Model pricing</h2><p>Input, output, and cached tokens may have different rates for each model. Refer to the model catalog in the console for current pricing.</p>` },
  '/docs/codex': { nav:'codex', eyebrow:'Codex', title:'Connect Codex', lead:'Use WarpGate API with the Codex CLI, desktop App, or IDE extension.', body:`<h2 id="overview">Configuration overview</h2><p>Codex uses the OpenAI-compatible Responses API. The Base URL must include <code>/v1</code>.</p>${code('config.toml',`model_provider = "warpgateapi_proxy"\n\n[model_providers.warpgateapi_proxy]\nname = "WarpGate API"\nbase_url = "https://warpgateapi.com/v1"\nenv_key = "WARPGATE_API_KEY"\nwire_api = "responses"\nrequires_openai_auth = false`)}${cards([['Install Codex','Install the CLI, App, or editor extension.','/docs/codex/install'],['Configure Codex','Add the model provider and set your API key.','/docs/codex/config']])}` },
  '/docs/codex/install': { nav:'codex', eyebrow:'Codex', title:'Install Codex', lead:'Choose the Codex CLI, desktop App, or IDE extension.', body:`<h2 id="cli">Codex CLI</h2>${code('Terminal','npm install -g @openai/codex\ncodex --version')}<h2 id="app">Codex App</h2><p>The desktop App and CLI can share the configuration stored in <code>~/.codex</code>.</p><h2 id="next">Next step</h2><p>Continue to <a href="#/docs/codex/config">configure WarpGate API</a>.</p>` },
  '/docs/codex/config': { nav:'codex', eyebrow:'Codex', title:'Configure Codex', lead:'Add a model provider and securely supply your API key through an environment variable.', body:`<h2 id="key">Set the API key</h2>${code('Terminal','export WARPGATE_API_KEY="your-wg-key"')}<h2 id="provider">Add the provider</h2><p>Edit <code>~/.codex/config.toml</code>:</p>${code('config.toml',`model_provider = "warpgateapi_proxy"\n\n[model_providers.warpgateapi_proxy]\nname = "WarpGate API"\nbase_url = "https://warpgateapi.com/v1"\nenv_key = "WARPGATE_API_KEY"\nwire_api = "responses"\nrequires_openai_auth = false`)}<h2 id="verify">Verify</h2>${code('Terminal','codex')}<div class="callout"><strong>Base URL</strong><p>Codex must use <code>https://warpgateapi.com/v1</code> with the <code>responses</code> wire API.</p></div>` },
  '/docs/api': { nav:'api', eyebrow:'Developers', title:'API reference', lead:'WarpGate API provides unified OpenAI-compatible endpoints.', body:`<h2 id="auth">Authentication</h2><p>Every request is authenticated with an HTTP Bearer token.</p>${code('HTTP','Authorization: Bearer YOUR_API_KEY')}<h2 id="endpoints">Endpoints</h2>${cards([['OpenAI compatible','/v1/chat/completions and /v1/responses.','/docs/api/openai']])}<h2 id="errors">Errors</h2><p>The API uses standard HTTP status codes. Handle <code>401</code> authentication failures, <code>429</code> rate limits, and temporary upstream <code>5xx</code> errors.</p>` },
  '/docs/api/openai': { nav:'api', eyebrow:'API', title:'OpenAI-compatible API', lead:'Use existing OpenAI SDKs by changing only the Base URL and API key.', body:`<h2 id="examples">Request examples</h2><p>Select your language. Every example below uses the Responses API.</p>${codeTabs([['JavaScript',`import OpenAI from "openai";\n\nconst client = new OpenAI({\n  apiKey: process.env.WARPGATE_API_KEY,\n  baseURL: "https://warpgateapi.com/v1",\n});\n\nconst response = await client.responses.create({\n  model: "gpt-5.4-mini",\n  input: "Hello",\n});\n\nconsole.log(response.output_text);`,'javascript'],['Python',`import os\nfrom openai import OpenAI\n\nclient = OpenAI(\n    api_key=os.environ["WARPGATE_API_KEY"],\n    base_url="https://warpgateapi.com/v1",\n)\n\nresponse = client.responses.create(\n    model="gpt-5.4-mini",\n    input="Hello",\n)\n\nprint(response.output_text)`,'python'],['curl',`curl https://warpgateapi.com/v1/responses \\\n+  -H "Authorization: Bearer $WARPGATE_API_KEY" \\\n+  -H "Content-Type: application/json" \\\n+  -d '{"model":"gpt-5.4-mini","input":"Hello"}'`,'shell']])}` },
  '/docs/faq': { nav:'faq', eyebrow:'Support', title:'Frequently asked questions', lead:'Common questions about endpoints, authentication, models, and billing.', body:`<h2 id="base-url">Which Base URL should I use?</h2><p>Use <code>https://warpgateapi.com/v1</code> with Codex and OpenAI SDKs.</p><h2 id="unauthorized">Why am I getting a 401?</h2><p>Check that your API key is complete and enabled, and that the request includes <code>Authorization: Bearer YOUR_API_KEY</code>.</p><h2 id="model">Why does the API say the model does not exist?</h2><p>Model availability may change. Use the exact model name shown in the console model catalog.</p><h2 id="rate-limit">What should I do after a 429?</h2><p>Reduce concurrency, add exponential-backoff retries, and confirm your account balance and token limits.</p>` }
}

const pagesByLocale = { zh: pagesZh, en: pagesEn }

const sidebar = document.querySelector('#sidebar-nav')
const modal=document.querySelector('#search-modal'), input=document.querySelector('#search-input'), results=document.querySelector('#search-results')

function path(){ return location.hash.slice(1).split('?')[0].split('::')[0] || '/docs' }
function renderChrome(){
  const labels = ui[currentLocale]
  document.documentElement.lang = currentLocale === 'zh' ? 'zh-CN' : 'en'
  document.querySelector('meta[name="description"]').content = currentLocale === 'zh' ? 'WarpGate API 文档 — 快速接入 Codex 与 OpenAI 兼容客户端。' : 'WarpGate API documentation for connecting Codex and OpenAI-compatible clients.'
  document.querySelector('#brand-link').setAttribute('aria-label', currentLocale === 'zh' ? 'WarpGate API Docs 首页' : 'WarpGate API Docs home')
  document.querySelector('.topnav').setAttribute('aria-label', currentLocale === 'zh' ? '主导航' : 'Main navigation')
  document.querySelector('[data-nav="docs"]').textContent = labels.docs
  document.querySelector('[data-nav="faq"]').textContent = labels.faq
  document.querySelector('#search-trigger').innerHTML = `<span>⌕</span> ${labels.search} <kbd>⌘ K</kbd>`
  document.querySelector('#search-trigger').setAttribute('aria-label', labels.searchLabel)
  document.querySelector('#language-toggle').textContent = labels.language
  document.querySelector('#language-toggle').setAttribute('aria-label', labels.switchLanguage)
  document.querySelector('#theme-toggle').setAttribute('aria-label', labels.theme)
  document.querySelector('.console-button').innerHTML = `${labels.console} <span>↗</span>`
  document.querySelector('#menu-button').setAttribute('aria-label', labels.menu)
  document.querySelector('#sidebar-nav').setAttribute('aria-label', labels.sidebar)
  document.querySelector('#toc-title').textContent = labels.toc
  document.querySelector('#search-panel').setAttribute('aria-label', labels.searchLabel)
  input.placeholder = labels.searchLabel
  document.querySelector('#search-select').textContent = labels.select
  document.querySelector('#search-open').textContent = labels.open
}
function renderSidebar(){
  sidebar.innerHTML = sectionsByLocale[currentLocale].map(section => `<div><h3>${section.title}</h3>${section.links.map(([label,link]) => `<a href="#${link}" data-path="${link}">${label}</a>`).join('')}</div>`).join('')
}
function render(){
  renderChrome()
  renderSidebar()
  const pages = pagesByLocale[currentLocale]
  const labels = ui[currentLocale]
  const current = path(), page = pages[current] || pages['/docs']
  document.title = `${page.title} · WarpGate API Docs`
  document.querySelectorAll('[data-nav]').forEach(a => a.classList.toggle('active', a.dataset.nav === page.nav))
  document.querySelectorAll('[data-path]').forEach(a => a.classList.toggle('active', a.dataset.path === current))
  document.querySelector('#article').innerHTML = `<div class="eyebrow">${page.eyebrow}</div><h1>${page.title}</h1><p class="lead">${page.lead}</p>${page.body}<hr><p>${labels.support} <a href="https://warpgateapi.com/dashboard">${labels.supportLink}</a> ${labels.supportEnd}</p>`
  const headings = [...document.querySelectorAll('#article h2')]
  document.querySelector('#toc-nav').innerHTML = headings.map(h => `<a href="#${current}::${h.id}" data-anchor="${h.id}">${h.textContent}</a>`).join('')
  document.querySelectorAll('.copy-code').forEach(btn => { btn.textContent = labels.copy; btn.onclick = () => copy(decodeURIComponent(btn.dataset.copy), btn) })
  document.querySelectorAll('.code-tabs').forEach(group => group.querySelectorAll('.code-tab').forEach(tab => tab.onclick = () => {
    group.querySelectorAll('.code-tab').forEach(item => { item.classList.toggle('active', item === tab); item.setAttribute('aria-selected', item === tab) })
    group.querySelectorAll('.code-tab-panel').forEach(panel => panel.classList.toggle('active', panel.dataset.panel === tab.dataset.tab))
  }))
  window.scrollTo(0,0); document.querySelector('#sidebar').classList.remove('open')
  const anchor = location.hash.split('::')[1]; if(anchor) setTimeout(() => document.getElementById(anchor)?.scrollIntoView(),0)
}
function copy(text, button){ navigator.clipboard.writeText(text); button.textContent=ui[currentLocale].copied; setTimeout(()=>button.textContent=ui[currentLocale].copy,1200) }
window.addEventListener('hashchange', render)

function openSearch(){modal.classList.add('open');modal.setAttribute('aria-hidden','false');input.value='';showResults('');setTimeout(()=>input.focus(),0)}
function closeSearch(){modal.classList.remove('open');modal.setAttribute('aria-hidden','true')}
function showResults(q){const searchIndex=Object.entries(pagesByLocale[currentLocale]).map(([p,v])=>({path:p,title:v.title,desc:v.lead}));const found=searchIndex.filter(x=>(x.title+x.desc).toLowerCase().includes(q.toLowerCase())).slice(0,8);results.innerHTML=found.length?found.map((x,i)=>`<a class="search-result ${i===0?'selected':''}" href="#${x.path}"><strong>${x.title}</strong><span>${x.desc}</span></a>`).join(''):`<div class="empty">${ui[currentLocale].noResults}</div>`}
document.querySelector('#search-trigger').onclick=openSearch;document.querySelector('.search-backdrop').onclick=closeSearch;input.oninput=()=>showResults(input.value)
document.addEventListener('keydown',e=>{if((e.metaKey||e.ctrlKey)&&e.key.toLowerCase()==='k'){e.preventDefault();openSearch()}if(e.key==='Escape')closeSearch();if(e.key==='Enter'&&modal.classList.contains('open')){document.querySelector('.search-result')?.click();closeSearch()}})
document.querySelector('#language-toggle').onclick=()=>{currentLocale=currentLocale==='zh'?'en':'zh';localStorage.docsLanguage=currentLocale;render();if(modal.classList.contains('open'))showResults(input.value)}
document.querySelector('#theme-toggle').onclick=()=>{document.documentElement.classList.toggle('light');localStorage.theme=document.documentElement.classList.contains('light')?'light':'dark'}
if(localStorage.theme==='light'||(!localStorage.theme&&matchMedia('(prefers-color-scheme:light)').matches))document.documentElement.classList.add('light')
document.querySelector('#menu-button').onclick=()=>document.querySelector('#sidebar').classList.toggle('open')
render()
