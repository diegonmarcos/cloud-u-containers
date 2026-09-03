'use client';

import { useState } from 'react';
import { Loader2, CheckCircle, AlertCircle } from 'lucide-react';
import { useTranslations } from 'next-intl';
import { isValidUnsubscribeUrl } from '@/lib/validation';

interface UnsubscribeBannerProps {
  listUnsubscribe: {
    http?: string;
    mailto?: string;
    preferred?: 'http' | 'mailto';
  };
  senderEmail: string;
  onDismiss: () => void;
}

export function UnsubscribeBanner({
  listUnsubscribe,
  senderEmail: _senderEmail,
  onDismiss
}: UnsubscribeBannerProps) {
  const t = useTranslations();
  const [showConfirm, setShowConfirm] = useState(false);
  const [processing, setProcessing] = useState(false);
  const [success, setSuccess] = useState(false);
  const [error, setError] = useState(false);

  const unsubMethod = listUnsubscribe.preferred;
  const unsubUrl = unsubMethod === 'http'
    ? listUnsubscribe.http
    : listUnsubscribe.mailto;

  if (!unsubUrl || !unsubMethod) {
    return null;
  }

  const handleUnsubscribe = async () => {
    if (!isValidUnsubscribeUrl(unsubUrl)) {
      setError(true);
      setProcessing(false);
      return;
    }

    setProcessing(true);

    try {
      if (unsubMethod === 'http') {
        window.open(unsubUrl, '_blank', 'noopener,noreferrer');
        setSuccess(true);
        setProcessing(false);
        setTimeout(onDismiss, 3000);
      } else {
        const link = document.createElement('a');
        link.href = unsubUrl;
        link.style.display = 'none';
        document.body.appendChild(link);
        link.click();
        document.body.removeChild(link);

        setSuccess(true);
        setProcessing(false);
        setTimeout(onDismiss, 3000);
      }
    } catch {
      setError(true);
      setProcessing(false);
    }
  };

  if (success) {
    return (
      <div className="flex items-center gap-2">
        <CheckCircle className="w-3.5 h-3.5 text-green-600 dark:text-green-400" />
        <span className="text-sm text-muted-foreground">
          {t(unsubMethod === 'http'
            ? 'email_viewer.unsubscribe_banner.success_http'
            : 'email_viewer.unsubscribe_banner.success_mailto'
          )}
        </span>
      </div>
    );
  }

  if (error) {
    return (
      <div className="flex items-center gap-2 flex-wrap">
        <AlertCircle className="w-3.5 h-3.5 text-red-600 dark:text-red-400" />
        <span className="text-sm text-red-600 dark:text-red-400">
          {t('email_viewer.unsubscribe_banner.error')}
        </span>
        <button
          onClick={onDismiss}
          className="text-sm text-muted-foreground hover:text-foreground bg-transparent hover:bg-transparent transition-colors min-h-[44px] md:min-h-0"
        >
          {t('email_viewer.unsubscribe_banner.dismiss')}
        </button>
      </div>
    );
  }

  return (
    <div className="flex items-center gap-2 flex-wrap">
      {showConfirm ? (
        <>
          <span className="text-sm text-muted-foreground">
            {t('email_viewer.unsubscribe_banner.confirm_title')}
          </span>
          <button
            onClick={handleUnsubscribe}
            disabled={processing}
            className="flex items-center gap-1.5 text-sm text-muted-foreground hover:text-foreground bg-transparent hover:bg-transparent transition-colors disabled:opacity-50 disabled:cursor-not-allowed min-h-[44px] md:min-h-0"
          >
            {processing && <Loader2 className="w-3.5 h-3.5 animate-spin" />}
            {t('email_viewer.unsubscribe_banner.confirm_button')}
          </button>
          <button
            onClick={() => setShowConfirm(false)}
            className="text-sm text-muted-foreground hover:text-foreground bg-transparent hover:bg-transparent transition-colors min-h-[44px] md:min-h-0"
          >
            {t('email_viewer.unsubscribe_banner.cancel')}
          </button>
        </>
      ) : (
        <button
          onClick={() => setShowConfirm(true)}
          className="text-sm text-muted-foreground hover:text-foreground bg-transparent hover:bg-transparent transition-colors min-h-[44px] md:min-h-0"
        >
          {t('email_viewer.unsubscribe_banner.button')}
        </button>
      )}
    </div>
  );
}
