import { NextResponse } from 'next/server';
import { NextRequest } from 'next/server';
import { getHeapStatistics } from 'v8';
import { logger } from '@/lib/logger';

const MEMORY_WARNING_THRESHOLD = 0.85;
const MEMORY_CRITICAL_THRESHOLD = 0.95;

interface HealthStatus {
  status: 'healthy' | 'degraded' | 'unhealthy';
  timestamp: string;
  uptime?: number;
  version?: string;
  memory?: {
    heapUsed: number;
    heapTotal: number;
    heapLimit: number;
    rss: number;
    external: number;
    heapUsagePercent: number;
  };
  environment?: string;
  nodeVersion?: string;
  warnings?: string[];
  reason?: string;
}

export async function GET(request: NextRequest) {
  const searchParams = request.nextUrl.searchParams;
  const detailed = searchParams.get('detailed') === 'true';

  try {
    const timestamp = new Date().toISOString();
    const memUsage = process.memoryUsage();
    const heapLimit = getHeapStatistics().heap_size_limit;
    const heapUsagePercent = (memUsage.heapUsed / heapLimit) * 100;

    let status: 'healthy' | 'degraded' | 'unhealthy' = 'healthy';
    const warnings: string[] = [];
    let httpStatus = 200;

    if (heapUsagePercent >= MEMORY_CRITICAL_THRESHOLD * 100) {
      status = 'unhealthy';
      httpStatus = 503;
    } else if (heapUsagePercent >= MEMORY_WARNING_THRESHOLD * 100) {
      status = 'degraded';
      warnings.push(`Memory usage high: ${heapUsagePercent.toFixed(1)}%`);
    }

    const response: HealthStatus = {
      status,
      timestamp,
    };

    if (status === 'unhealthy') {
      response.reason = `Memory usage critical: ${heapUsagePercent.toFixed(1)}%`;
    }

    if (detailed) {
      response.uptime = process.uptime();
      response.version = process.env.npm_package_version || '0.1.0';
      response.memory = {
        heapUsed: memUsage.heapUsed,
        heapTotal: memUsage.heapTotal,
        heapLimit,
        rss: memUsage.rss,
        external: memUsage.external,
        heapUsagePercent: Number(heapUsagePercent.toFixed(2)),
      };
      response.environment = process.env.NODE_ENV || 'development';
      response.nodeVersion = process.version;

      if (warnings.length > 0) {
        response.warnings = warnings;
      }
    }

    logger.info('Health check', { status, detailed });

    return NextResponse.json(response, {
      status: httpStatus,
      headers: {
        'Cache-Control': 'no-store, no-cache, must-revalidate',
        'Pragma': 'no-cache',
        'Expires': '0',
      },
    });

  } catch (error) {
    logger.error('Health check failed', { error: error instanceof Error ? error.message : 'Unknown error' });
    return NextResponse.json(
      {
        status: 'unhealthy',
        timestamp: new Date().toISOString(),
        reason: error instanceof Error ? error.message : 'Unknown error',
      },
      { status: 503 }
    );
  }
}

export async function HEAD() {
  try {
    const memUsage = process.memoryUsage();
    const heapLimit = getHeapStatistics().heap_size_limit;
    const heapUsagePercent = (memUsage.heapUsed / heapLimit) * 100;

    if (heapUsagePercent >= MEMORY_CRITICAL_THRESHOLD * 100) {
      return new Response(null, { status: 503 });
    }

    return new Response(null, { status: 200 });
  } catch {
    return new Response(null, { status: 503 });
  }
}
