/*
Copyright (C) 2023-2026 QuantumNous

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as
published by the Free Software Foundation, either version 3 of the
License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
GNU Affero General Public License for more details.

You should have received a copy of the GNU Affero General Public License
along with this program. If not, see <https://www.gnu.org/licenses/>.

For commercial licensing, please contact support@quantumnous.com
*/
import {
  Copy01Icon,
  Download01Icon,
  FileCodeIcon,
} from '@hugeicons/core-free-icons'
import { HugeiconsIcon } from '@hugeicons/react'
import { useQuery } from '@tanstack/react-query'
import { createFileRoute, redirect } from '@tanstack/react-router'
import { useEffect, useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'

import { Button } from '@/components/ui/button'
import { Combobox } from '@/components/ui/combobox'
import {
  Field,
  FieldDescription,
  FieldGroup,
  FieldLabel,
} from '@/components/ui/field'
import { Input } from '@/components/ui/input'
import { NativeSelect, NativeSelectOption } from '@/components/ui/native-select'
import { Spinner } from '@/components/ui/spinner'
import { CHANNEL_TYPE_OPTIONS } from '@/features/channels/constants'
import { getChannelTypeIcon } from '@/features/channels/lib'
import { getApiKeys, fetchTokenKey } from '@/features/keys/api'
import { API_KEY_STATUS } from '@/features/keys/constants'
import { useCopyToClipboard } from '@/hooks/use-copy-to-clipboard'
import { getSelf } from '@/lib/api'
import { getLobeIcon } from '@/lib/lobe-icon'
import { useAuthStore } from '@/stores/auth-store'

type ProviderType = 'openai'

const DEFAULT_PROVIDER_NAME = 'WarpGate API'
const CODEX_DOWNLOAD_URL = 'https://openai.com/codex/'
const CODEX_INSTALLER_URL =
  'https://raw.githubusercontent.com/aeolialiu2051/warpgateapi-setups/main/codex/install.sh'
const DIACRITIC_PATTERN = /[\u0300-\u036f]/g
const NON_ALPHANUMERIC_PATTERN = /[^a-z0-9]/g
const CODEX_PROVIDER_OPTIONS: {
  channelType: number
  providerType: ProviderType
}[] = [{ channelType: 1, providerType: 'openai' }]

let sessionVerified = false

function createCodexSetupCommand(apiKey: string, configToml: string): string {
  const payload = JSON.stringify({ version: 1, apiKey, configToml })
  const bytes = new TextEncoder().encode(payload)
  let binary = ''
  for (const byte of bytes) binary += String.fromCharCode(byte)
  const encodedPayload = btoa(binary)
    .replaceAll('+', '-')
    .replaceAll('/', '_')
    .replace(/=+$/, '')

  return `curl -fsSL ${CODEX_INSTALLER_URL} | bash -s -- '${encodedPayload}'`
}

async function requireCodexAuth(locationHref: string) {
  const { auth } = useAuthStore.getState()

  if (!auth.user) {
    throw redirect({
      to: '/sign-in',
      search: { redirect: locationHref },
    })
  }

  if (sessionVerified) return

  const res = await getSelf().catch(() => null)
  if (res?.success && res.data) {
    auth.setUser(res.data)
    sessionVerified = true
    return
  }

  auth.reset()
  throw redirect({
    to: '/sign-in',
    search: { redirect: locationHref },
  })
}

export const Route = createFileRoute('/codex/')({
  beforeLoad: ({ location }) => requireCodexAuth(location.href),
  component: CodexPage,
})

function CodexPage() {
  const { t } = useTranslation()
  const { copyToClipboard } = useCopyToClipboard()
  const [providerType, setProviderType] = useState<ProviderType>('openai')
  const [providerName, setProviderName] = useState(DEFAULT_PROVIDER_NAME)
  const [selectedKeyId, setSelectedKeyId] = useState('')

  const { data: apiKeysData, isPending: isLoadingKeys } = useQuery({
    queryKey: ['codex-api-keys'],
    queryFn: () => getApiKeys({ size: 100 }),
    retry: false,
  })

  const apiKeys = useMemo(
    () =>
      (apiKeysData?.data?.items ?? []).filter(
        (apiKey) => apiKey.status === API_KEY_STATUS.ENABLED
      ),
    [apiKeysData?.data?.items]
  )
  const providerTypeOptions = useMemo(
    () =>
      CODEX_PROVIDER_OPTIONS.map(({ channelType, providerType }) => {
        const channelOption = CHANNEL_TYPE_OPTIONS.find(
          (option) => option.value === channelType
        )
        return {
          value: providerType,
          label: t(channelOption?.label || providerType),
          icon: getLobeIcon(`${getChannelTypeIcon(channelType)}.Color`, 16),
        }
      }),
    [t]
  )

  useEffect(() => {
    if (apiKeys.length === 0) return
    const hasSelectedKey = apiKeys.some(
      (apiKey) => String(apiKey.id) === selectedKeyId
    )
    if (hasSelectedKey) return
    setSelectedKeyId(String(apiKeys[0].id))
  }, [apiKeys, selectedKeyId])

  const {
    data: fetchedTokenKey,
    isFetching: isLoadingTokenKey,
    isError: isTokenKeyError,
  } = useQuery({
    queryKey: ['codex-token-key', selectedKeyId],
    queryFn: async () => {
      const res = await fetchTokenKey(Number(selectedKeyId))
      if (!res.success || !res.data?.key) {
        throw new Error(res.message || t('Failed to load API key'))
      }
      return res.data.key.startsWith('sk-')
        ? res.data.key
        : `sk-${res.data.key}`
    },
    enabled: selectedKeyId !== '',
    retry: false,
  })

  const resolvedProviderName = providerName.trim() || DEFAULT_PROVIDER_NAME
  const providerId = `${
    resolvedProviderName
      .normalize('NFKD')
      .toLowerCase()
      .replace(DIACRITIC_PATTERN, '')
      .replace(NON_ALPHANUMERIC_PATTERN, '') || 'custom'
  }_proxy`
  const modelProviderConfig = `model_provider = "${providerId}"`
  const providerConfig = `[model_providers.${providerId}]
name = ${JSON.stringify(resolvedProviderName)}
base_url = "https://warpgateapi.com/v1"
env_key = "WARPGATE_API_KEY"
wire_api = "responses"
requires_openai_auth = false`
  const codexConfig = `${modelProviderConfig}\n\n${providerConfig}`
  const codexSetupCommand = fetchedTokenKey
    ? createCodexSetupCommand(fetchedTokenKey, codexConfig)
    : ''

  let apiKeyOptions
  if (apiKeys.length === 0) {
    apiKeyOptions = (
      <NativeSelectOption value=''>
        {isLoadingKeys ? t('Loading...') : t('No API keys found')}
      </NativeSelectOption>
    )
  } else {
    apiKeyOptions = apiKeys.map((apiKey) => (
      <NativeSelectOption key={apiKey.id} value={String(apiKey.id)}>
        {apiKey.name}
      </NativeSelectOption>
    ))
  }

  const handleProviderTypeChange = (value: string | null) => {
    if (value !== 'openai') return
    setProviderType(value)
  }

  return (
    <main className='bg-background px-4 py-6 sm:px-6 lg:py-8'>
      <div className='mx-auto flex min-h-full w-full max-w-6xl flex-col gap-7'>
        <header className='flex flex-col gap-4'>
          <div className='flex flex-col gap-3'>
            <h1 className='text-3xl font-semibold tracking-normal sm:text-5xl'>
              {t('Configure CodeX')}
            </h1>
            <p className='text-muted-foreground max-w-4xl text-xl leading-relaxed sm:text-2xl'>
              {t(
                'Select an API key, add it to your environment, then paste the generated configuration into the CodeX config file.'
              )}
            </p>
          </div>
        </header>

        <div className='grid gap-6 lg:grid-cols-[minmax(0,0.8fr)_minmax(0,1.2fr)] xl:gap-8'>
          <FieldGroup className='bg-card/40 gap-5 rounded-lg border p-5 shadow-sm sm:p-6'>
            <Field>
              <FieldLabel htmlFor='codex-provider-type'>
                {t('Provider Type')}
              </FieldLabel>
              <Combobox
                id='codex-provider-type'
                className='w-full'
                options={providerTypeOptions}
                value={providerType}
                onValueChange={handleProviderTypeChange}
                placeholder={t('Select channel type')}
                searchPlaceholder={t('Search channel type...')}
                emptyText={t('No channel type found.')}
              />
            </Field>

            <Field>
              <FieldLabel htmlFor='codex-provider-name'>
                {t('Provider Name')}
              </FieldLabel>
              <Input
                id='codex-provider-name'
                value={providerName}
                onChange={(event) => setProviderName(event.target.value)}
                placeholder={DEFAULT_PROVIDER_NAME}
              />
            </Field>

            <Field>
              <FieldLabel htmlFor='codex-api-key'>{t('API Key')}</FieldLabel>
              <NativeSelect
                id='codex-api-key'
                className='w-full'
                value={selectedKeyId}
                onChange={(event) => setSelectedKeyId(event.target.value)}
                disabled={isLoadingKeys && apiKeys.length === 0}
              >
                {apiKeyOptions}
              </NativeSelect>
              <FieldDescription>
                {isTokenKeyError
                  ? t('Failed to load API key')
                  : t('Only enabled API keys can be used.')}
              </FieldDescription>
            </Field>

            <div className='bg-muted/30 flex min-h-24 items-center rounded-lg border p-4'>
              {isLoadingTokenKey ? (
                <div className='text-muted-foreground flex w-full items-center justify-center gap-2 text-sm'>
                  <Spinner />
                  {t('Loading API key...')}
                </div>
              ) : (
                <code className='w-full overflow-auto font-mono text-sm break-all'>
                  {fetchedTokenKey || t('Select an API key to view it.')}
                </code>
              )}
            </div>
          </FieldGroup>

          <section className='bg-card/40 flex flex-col gap-5 rounded-lg border p-5 shadow-sm sm:p-6'>
            <div className='flex items-start gap-3'>
              <div className='bg-muted text-muted-foreground flex size-9 shrink-0 items-center justify-center rounded-lg border'>
                <HugeiconsIcon
                  icon={FileCodeIcon}
                  strokeWidth={2}
                  aria-hidden='true'
                />
              </div>
              <div className='flex flex-col gap-1'>
                <h2 className='font-semibold'>{t('CodeX configuration')}</h2>
                <p className='text-muted-foreground text-sm leading-5'>
                  {t(
                    'Edit ~/.codex/config.toml using the terminal or CodeX Settings → Configuration → Open config.toml.'
                  )}
                </p>
              </div>
            </div>

            <div className='flex flex-col gap-2'>
              <div>
                <h3 className='text-sm font-medium'>{t('File beginning')}</h3>
              </div>
              <pre className='bg-muted/30 overflow-auto rounded-lg border p-4 font-mono text-sm leading-6 whitespace-pre'>
                <code>{modelProviderConfig}</code>
              </pre>
            </div>

            <div className='flex flex-1 flex-col gap-2'>
              <div>
                <h3 className='text-sm font-medium'>{t('File end')}</h3>
              </div>
              <pre className='bg-muted/30 min-h-52 flex-1 overflow-auto rounded-lg border p-4 font-mono text-sm leading-6 whitespace-pre'>
                <code>{providerConfig}</code>
              </pre>
            </div>
          </section>
        </div>

        <div className='grid gap-3 border-t pt-5 sm:grid-cols-2 sm:gap-4 lg:grid-cols-4'>
          <Button
            variant='outline'
            size='lg'
            className='h-12 text-base'
            disabled={!fetchedTokenKey}
            onClick={() => copyToClipboard(fetchedTokenKey || '')}
          >
            <HugeiconsIcon
              icon={Copy01Icon}
              strokeWidth={2}
              data-icon='inline-start'
            />
            {t('Copy API key')}
          </Button>
          <Button
            variant='outline'
            size='lg'
            className='h-12 text-base'
            onClick={() => copyToClipboard(codexConfig)}
          >
            <HugeiconsIcon
              icon={Copy01Icon}
              strokeWidth={2}
              data-icon='inline-start'
            />
            {t('Copy configuration')}
          </Button>
          <Button
            variant='outline'
            size='lg'
            className='h-12 text-base'
            disabled={!codexSetupCommand}
            onClick={() => copyToClipboard(codexSetupCommand)}
          >
            <HugeiconsIcon
              icon={FileCodeIcon}
              strokeWidth={2}
              data-icon='inline-start'
            />
            {t('One-click configure CodeX')}
          </Button>
          <Button
            size='lg'
            className='h-12 text-base'
            render={
              <a href={CODEX_DOWNLOAD_URL} target='_blank' rel='noreferrer' />
            }
          >
            <HugeiconsIcon
              icon={Download01Icon}
              strokeWidth={2}
              data-icon='inline-start'
            />
            {t('Download CodeX App')}
          </Button>
        </div>
      </div>
    </main>
  )
}
