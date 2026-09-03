import { getRequestConfig } from 'next-intl/server';
import { routing, type Locale } from './routing';

export default getRequestConfig(async ({ requestLocale }) => {
  let locale = await requestLocale;

  if (!locale || !routing.locales.includes(locale as Locale)) {
    locale = routing.defaultLocale;
  }

  const messages = (await import(`../locales/${locale}/common.json`)).default;

  return {
    locale,
    messages,
    timeZone: 'Europe/Paris',
    now: new Date()
  };
});
