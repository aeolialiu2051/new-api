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
import { useEffect, useMemo, useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { createFileRoute, redirect } from '@tanstack/react-router'
import { Copy, Loader2, Share2 } from 'lucide-react'
import { QRCodeSVG } from 'qrcode.react'
import { useTranslation } from 'react-i18next'
import { toast } from 'sonner'
import { useAuthStore } from '@/stores/auth-store'
import { getSelf } from '@/lib/api'
import { getLobeIcon } from '@/lib/lobe-icon'
import { useCopyToClipboard } from '@/hooks/use-copy-to-clipboard'
import { CHANNEL_TYPE_OPTIONS } from '@/features/channels/constants'
import { getChannelTypeIcon } from '@/features/channels/lib'
import { fetchTokenKey, getApiKeys } from '@/features/keys/api'
import { API_KEY_STATUS } from '@/features/keys/constants'
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

type ProviderType = 'openai'

const DEFAULT_PROVIDER_NAME = 'WarpGateAPI'
const DEFAULT_BASE_URL_BY_PROVIDER: Record<ProviderType, string> = {
  openai: 'https://warpgateapi.com/v1',
}
const KELIVO_PROVIDER_OPTIONS: {
  channelType: number
  providerType: ProviderType
}[] = [
  { channelType: 1, providerType: 'openai' },
]

let sessionVerified = false

async function requireKelivoAuth(locationHref: string) {
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

function encodeUtf8Base64(value: string): string {
  const bytes = new TextEncoder().encode(value)
  let binary = ''
  bytes.forEach((byte) => {
    binary += String.fromCharCode(byte)
  })
  return window.btoa(binary)
}

function encodeProviderConfig({
  providerType,
  name,
  apiKey,
  baseUrl,
}: {
  providerType: ProviderType
  name: string
  apiKey: string
  baseUrl: string
}): string {
  const payload: {
    type: ProviderType
    name: string
    apiKey: string
    baseUrl?: string
  } = {
    type: providerType,
    name,
    apiKey,
  }

  payload.baseUrl = baseUrl

  const json = JSON.stringify(payload)
  return `ai-provider:v1:${encodeUtf8Base64(json)}`
}

export const Route = createFileRoute('/kelivo/')({
  beforeLoad: ({ location }) => requireKelivoAuth(location.href),
  component: KelivoPage,
})

function KelivoPage() {
  const { t } = useTranslation()
  const { copyToClipboard } = useCopyToClipboard()
  const [providerType, setProviderType] = useState<ProviderType>('openai')
  const [name, setName] = useState(DEFAULT_PROVIDER_NAME)
  const [baseUrl, setBaseUrl] = useState(DEFAULT_BASE_URL_BY_PROVIDER.openai)
  const [selectedKeyId, setSelectedKeyId] = useState('')

  const providerTypeOptions = useMemo(
    () =>
      KELIVO_PROVIDER_OPTIONS.map(({ channelType, providerType }) => {
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

  const { data: apiKeysData, isPending: isLoadingKeys } = useQuery({
    queryKey: ['kelivo-api-keys'],
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
    isPending: isLoadingTokenKey,
    isError: isTokenKeyError,
  } = useQuery({
    queryKey: ['kelivo-token-key', selectedKeyId],
    queryFn: async () => {
      const res = await fetchTokenKey(Number(selectedKeyId))
      if (!res.success || !res.data?.key) {
        throw new Error(res.message || t('Failed to load API key'))
      }
      return res.data.key
    },
    enabled: selectedKeyId !== '',
    retry: false,
  })

  const shareString = useMemo(() => {
    if (!fetchedTokenKey || !name.trim()) return ''
    return encodeProviderConfig({
      providerType,
      name: name.trim(),
      apiKey: fetchedTokenKey,
      baseUrl: baseUrl.trim(),
    })
  }, [baseUrl, fetchedTokenKey, name, providerType])

  const handleProviderTypeChange = (value: string | null) => {
    if (value !== 'openai') return
    setProviderType(value)
    setBaseUrl(DEFAULT_BASE_URL_BY_PROVIDER[value])
  }

  const handleShare = async () => {
    if (!shareString) {
      toast.error(t('Please complete the provider configuration first'))
      return
    }

    if (!navigator.share) {
      await copyToClipboard(shareString)
      return
    }

    try {
      await navigator.share({
        title: 'Kelivo',
        text: shareString,
      })
    } catch (error) {
      if (error instanceof DOMException && error.name === 'AbortError') return
      toast.error(t('Share failed'))
    }
  }

  return (
    <main className='bg-background px-4 py-6 sm:px-6 lg:py-8'>
      <div className='mx-auto flex min-h-full w-full max-w-6xl flex-col'>
        <div className='flex flex-1 flex-col gap-7'>
          <header className='flex flex-col gap-4'>
            <h1 className='text-3xl font-semibold tracking-normal sm:text-5xl'>
              {t('Share vendor configuration')}
            </h1>
            <p className='text-muted-foreground max-w-4xl text-xl leading-relaxed sm:text-2xl'>
              {t('Copy the share string below, or share it with a QR code.')}
            </p>
          </header>

          <div className='grid gap-6 lg:grid-cols-[minmax(0,1fr)_minmax(22rem,26rem)] lg:items-start xl:gap-8'>
            <FieldGroup className='bg-card/40 gap-5 rounded-lg border p-5 shadow-sm sm:p-6'>
              <Field>
                <FieldLabel htmlFor='kelivo-provider-type'>
                  {t('Provider Type')}
                </FieldLabel>
                <Combobox
                  id='kelivo-provider-type'
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
                <FieldLabel htmlFor='kelivo-provider-name'>
                  {t('Provider Name')}
                </FieldLabel>
                <Input
                  id='kelivo-provider-name'
                  value={name}
                  onChange={(event) => setName(event.target.value)}
                  placeholder={DEFAULT_PROVIDER_NAME}
                />
              </Field>

              <Field>
                <FieldLabel htmlFor='kelivo-api-key'>
                  {t('API Key')}
                </FieldLabel>
                <NativeSelect
                  id='kelivo-api-key'
                  className='w-full'
                  value={selectedKeyId}
                  onChange={(event) => setSelectedKeyId(event.target.value)}
                  disabled={isLoadingKeys && apiKeys.length === 0}
                >
                  {apiKeys.length === 0 ? (
                    <NativeSelectOption value=''>
                      {isLoadingKeys ? t('Loading...') : t('No API keys found')}
                    </NativeSelectOption>
                  ) : (
                    apiKeys.map((apiKey) => (
                      <NativeSelectOption
                        key={apiKey.id}
                        value={String(apiKey.id)}
                      >
                        {apiKey.name}
                      </NativeSelectOption>
                    ))
                  )}
                </NativeSelect>
                <FieldDescription>
                  {isTokenKeyError
                    ? t('Failed to load API key')
                    : t('Only enabled API keys can be shared.')}
                </FieldDescription>
              </Field>

              <Field>
                <FieldLabel htmlFor='kelivo-base-url'>
                  {t('Base URL')}
                </FieldLabel>
                <Input
                  id='kelivo-base-url'
                  value={baseUrl}
                  onChange={(event) => setBaseUrl(event.target.value)}
                  placeholder={DEFAULT_BASE_URL_BY_PROVIDER[providerType]}
                />
              </Field>
            </FieldGroup>

            <div className='bg-card/40 flex flex-col gap-4 rounded-lg border p-5 shadow-sm sm:p-6'>
              <section
                className='flex justify-center'
                aria-label={t('Vendor QR code preview')}
              >
                <div className='flex aspect-square w-full max-w-[21rem] items-center justify-center bg-white p-4 ring-1 ring-border sm:p-5'>
                  {shareString ? (
                    <QRCodeSVG
                      value={shareString}
                      className='h-auto w-full'
                      size={320}
                      level='M'
                      marginSize={2}
                    />
                  ) : (
                    <div className='flex aspect-square w-full items-center justify-center text-center text-sm text-neutral-500'>
                      {isLoadingTokenKey ? (
                        <Loader2 className='animate-spin' />
                      ) : (
                        t('Complete the form to generate a QR code.')
                      )}
                    </div>
                  )}
                </div>
              </section>

              <p className='bg-muted/30 text-muted-foreground max-h-40 overflow-auto rounded-lg border p-3 font-mono text-xs leading-5 break-all sm:text-sm'>
                {shareString || t('Generated share string will appear here.')}
              </p>
            </div>
          </div>
        </div>

        <div className='mt-6 grid gap-3 border-t pt-5 sm:grid-cols-2 sm:gap-4'>
          <Button
            variant='outline'
            size='lg'
            className='h-12 text-base'
            disabled={!shareString}
            onClick={() => copyToClipboard(shareString)}
          >
            <Copy data-icon='inline-start' />
            {t('Copy')}
          </Button>
          <Button
            variant='outline'
            size='lg'
            className='h-12 text-base'
            disabled={!shareString}
            onClick={handleShare}
          >
            <Share2 data-icon='inline-start' />
            {t('Share configuration')}
          </Button>
        </div>
      </div>
    </main>
  )
}
