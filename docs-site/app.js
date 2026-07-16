const sections = [
  { title: '开始使用', links: [['文档总览','/docs'],['快速开始','/docs/quickstart'],['充值与账单','/docs/billing']] },
  { title: 'Codex', links: [['概览','/docs/codex'],['安装指南','/docs/codex/install'],['配置教程','/docs/codex/config']] },
  { title: '开发者', links: [['API 参考','/docs/api'],['OpenAI 兼容接口','/docs/api/openai'],['常见问题','/docs/faq']] }
]

const cards = items => `<div class="doc-grid">${items.map(([title,desc,path]) => {
  const external = path.startsWith('http')
  return `<a class="doc-card" href="${external ? path : `#${path}`}"${external ? ' target="_blank" rel="noreferrer"' : ''}><strong>${title} <span style="float:right">→</span></strong><span>${desc}</span></a>`
}).join('')}</div>`
const code = (title, value) => `<div class="code-block"><div class="code-title">${title}</div><button class="copy-code" data-copy="${encodeURIComponent(value)}">复制</button><pre>${value.replaceAll('&','&amp;').replaceAll('<','&lt;')}</pre></div>`

const pages = {
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
  '/docs/api/openai': { nav:'api', eyebrow:'API', title:'OpenAI 兼容接口', lead:'使用现有 OpenAI SDK，只需替换 Base URL 和 API Key。', body:`<h2 id="javascript">JavaScript</h2>${code('JavaScript',`import OpenAI from "openai";\n\nconst client = new OpenAI({\n  apiKey: process.env.WARPGATE_API_KEY,\n  baseURL: "https://warpgateapi.com/v1",\n});\n\nconst response = await client.responses.create({\n  model: "gpt-5.4-mini",\n  input: "Hello",\n});`)}<h2 id="python">Python</h2>${code('Python',`from openai import OpenAI\n\nclient = OpenAI(\n    api_key=os.environ["WARPGATE_API_KEY"],\n    base_url="https://warpgateapi.com/v1",\n)`)} ` },
  '/docs/faq': { nav:'faq', eyebrow:'支持', title:'常见问题', lead:'关于地址、鉴权、模型和费用的高频问题。', body:`<h2 id="base-url">Base URL 应该填什么？</h2><p>Codex 和 OpenAI SDK 使用 <code>https://warpgateapi.com/v1</code>。</p><h2 id="unauthorized">为什么返回 401？</h2><p>检查 API Key 是否完整、是否启用，以及请求头是否为 <code>Authorization: Bearer YOUR_API_KEY</code>。</p><h2 id="model">为什么提示模型不存在？</h2><p>模型可用性可能调整，请使用控制台模型广场中展示的准确模型名称。</p><h2 id="rate-limit">遇到 429 怎么办？</h2><p>降低并发、加入指数退避重试，并确认账户余额和令牌额度。</p>` }
}

const sidebar = document.querySelector('#sidebar-nav')
sidebar.innerHTML = sections.map(s => `<div><h3>${s.title}</h3>${s.links.map(([label,path]) => `<a href="#${path}" data-path="${path}">${label}</a>`).join('')}</div>`).join('')

function path(){ return location.hash.slice(1).split('?')[0] || '/docs' }
function render(){
  const current = path(), page = pages[current] || pages['/docs']
  document.title = `${page.title} · WarpGate API Docs`
  document.querySelectorAll('[data-nav]').forEach(a => a.classList.toggle('active', a.dataset.nav === page.nav))
  document.querySelectorAll('[data-path]').forEach(a => a.classList.toggle('active', a.dataset.path === current))
  document.querySelector('#article').innerHTML = `<div class="eyebrow">${page.eyebrow}</div><h1>${page.title}</h1><p class="lead">${page.lead}</p>${page.body}<hr><p>没有找到答案？请前往 <a href="https://warpgateapi.com/dashboard">WarpGate API 控制台</a> 获取支持。</p>`
  const headings = [...document.querySelectorAll('#article h2')]
  document.querySelector('#toc-nav').innerHTML = headings.map(h => `<a href="#${current}::${h.id}" data-anchor="${h.id}">${h.textContent}</a>`).join('')
  document.querySelectorAll('.copy-code').forEach(btn => btn.onclick = () => copy(decodeURIComponent(btn.dataset.copy), btn))
  window.scrollTo(0,0); document.querySelector('#sidebar').classList.remove('open')
  const anchor = location.hash.split('::')[1]; if(anchor) setTimeout(() => document.getElementById(anchor)?.scrollIntoView(),0)
}
function copy(text, button){ navigator.clipboard.writeText(text); const old=button.textContent; button.textContent='已复制'; setTimeout(()=>button.textContent=old,1200) }
window.addEventListener('hashchange', render); render()

const modal=document.querySelector('#search-modal'), input=document.querySelector('#search-input'), results=document.querySelector('#search-results')
const searchIndex=Object.entries(pages).map(([p,v])=>({path:p,title:v.title,desc:v.lead}))
function openSearch(){modal.classList.add('open');modal.setAttribute('aria-hidden','false');input.value='';showResults('');setTimeout(()=>input.focus(),0)}
function closeSearch(){modal.classList.remove('open');modal.setAttribute('aria-hidden','true')}
function showResults(q){const found=searchIndex.filter(x=>(x.title+x.desc).toLowerCase().includes(q.toLowerCase())).slice(0,8);results.innerHTML=found.length?found.map((x,i)=>`<a class="search-result ${i===0?'selected':''}" href="#${x.path}"><strong>${x.title}</strong><span>${x.desc}</span></a>`).join(''):'<div class="empty">没有找到相关文档</div>'}
document.querySelector('#search-trigger').onclick=openSearch;document.querySelector('.search-backdrop').onclick=closeSearch;input.oninput=()=>showResults(input.value)
document.addEventListener('keydown',e=>{if((e.metaKey||e.ctrlKey)&&e.key.toLowerCase()==='k'){e.preventDefault();openSearch()}if(e.key==='Escape')closeSearch();if(e.key==='Enter'&&modal.classList.contains('open')){document.querySelector('.search-result')?.click();closeSearch()}})
document.querySelector('#theme-toggle').onclick=()=>{document.documentElement.classList.toggle('light');localStorage.theme=document.documentElement.classList.contains('light')?'light':'dark'}
if(localStorage.theme==='light'||(!localStorage.theme&&matchMedia('(prefers-color-scheme:light)').matches))document.documentElement.classList.add('light')
document.querySelector('#menu-button').onclick=()=>document.querySelector('#sidebar').classList.toggle('open')
