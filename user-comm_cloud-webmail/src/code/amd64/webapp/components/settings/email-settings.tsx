"use client";

import { useState } from 'react';
import { useTranslations } from 'next-intl';
import { useSettingsStore } from '@/stores/settings-store';
import { SettingsSection, SettingItem, Select, ToggleSwitch } from './settings-section';
import { TrustedSendersModal } from '@/components/trusted-senders-modal';
import { ChevronRight } from 'lucide-react';

export function EmailSettings() {
  const t = useTranslations('settings.email_behavior');
  const [showTrustedModal, setShowTrustedModal] = useState(false);

  const {
    markAsReadDelay,
    deleteAction,
    showPreview,
    emailsPerPage,
    externalContentPolicy,
    trustedSenders,
    domainFaviconAvatars,
    updateSetting,
  } = useSettingsStore();

  // Get count label for trusted senders button
  const getTrustedSendersCount = () => {
    const count = trustedSenders.length;
    if (count === 0) return t('trusted_senders.count_zero');
    if (count === 1) return t('trusted_senders.count_one');
    return t('trusted_senders.count_other', { count });
  };

  return (
    <SettingsSection title={t('title')} description={t('description')}>
      {/* Mark as Read */}
      <SettingItem label={t('mark_read.label')} description={t('mark_read.description')}>
        <Select
          value={markAsReadDelay.toString()}
          onChange={(value) => updateSetting('markAsReadDelay', parseInt(value))}
          options={[
            { value: '0', label: t('mark_read.instant') },
            { value: '3000', label: t('mark_read.delay_3s') },
            { value: '5000', label: t('mark_read.delay_5s') },
            { value: '-1', label: t('mark_read.never') },
          ]}
        />
      </SettingItem>

      {/* Delete Action */}
      <SettingItem label={t('delete_action.label')} description={t('delete_action.description')}>
        <Select
          value={deleteAction}
          onChange={(value) => updateSetting('deleteAction', value as 'trash' | 'permanent')}
          options={[
            { value: 'trash', label: t('delete_action.trash') },
            { value: 'permanent', label: t('delete_action.permanent') },
          ]}
        />
      </SettingItem>

      {/* Show Preview */}
      <SettingItem label={t('show_preview.label')} description={t('show_preview.description')}>
        <ToggleSwitch checked={showPreview} onChange={(checked) => updateSetting('showPreview', checked)} />
      </SettingItem>

      {/* Emails Per Page */}
      <SettingItem label={t('emails_per_page.label')} description={t('emails_per_page.description')}>
        <Select
          value={emailsPerPage.toString()}
          onChange={(value) => updateSetting('emailsPerPage', parseInt(value))}
          options={[
            { value: '25', label: t('emails_per_page.25') },
            { value: '50', label: t('emails_per_page.50') },
            { value: '100', label: t('emails_per_page.100') },
          ]}
        />
      </SettingItem>

      {/* External Content */}
      <SettingItem label={t('external_content.label')} description={t('external_content.description')}>
        <Select
          value={externalContentPolicy}
          onChange={(value) =>
            updateSetting('externalContentPolicy', value as 'ask' | 'block' | 'allow')
          }
          options={[
            { value: 'ask', label: t('external_content.ask') },
            { value: 'block', label: t('external_content.block') },
            { value: 'allow', label: t('external_content.allow') },
          ]}
        />
      </SettingItem>

      {/* Trusted Senders */}
      <SettingItem label={t('trusted_senders.label')} description={t('trusted_senders.description')}>
        <button
          onClick={() => setShowTrustedModal(true)}
          className="flex items-center gap-2 px-3 py-1.5 bg-muted hover:bg-accent rounded-md transition-colors"
        >
          <span className="text-sm text-foreground">{getTrustedSendersCount()}</span>
          <ChevronRight className="w-4 h-4 text-muted-foreground" />
        </button>
      </SettingItem>

      {/* Domain Favicon Avatars */}
      <SettingItem label={t('domain_favicon_avatars.label')} description={t('domain_favicon_avatars.description')}>
        <ToggleSwitch
          checked={domainFaviconAvatars}
          onChange={(checked) => updateSetting('domainFaviconAvatars', checked)}
        />
      </SettingItem>

      {/* Trusted Senders Modal */}
      <TrustedSendersModal
        isOpen={showTrustedModal}
        onClose={() => setShowTrustedModal(false)}
      />
    </SettingsSection>
  );
}
