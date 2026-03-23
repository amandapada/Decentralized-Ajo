import { NextRequest, NextResponse } from 'next/server';
import { prisma } from '@/lib/prisma';
import { verifyToken, extractToken } from '@/lib/auth';
import { validateBody, applyRateLimit } from '@/lib/api-helpers';
import { CreateCircleSchema } from '@/lib/validations/circle';
import type { CreateCircleInput } from '@/lib/validations/circle';
import { RATE_LIMITS } from '@/lib/rate-limit';

export async function POST(request: NextRequest) {
  const token = extractToken(request.headers.get('authorization'));
  if (!token) return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });

  const payload = verifyToken(token);
  if (!payload) return NextResponse.json({ error: 'Invalid or expired token' }, { status: 401 });

  const rateLimited = applyRateLimit(request, RATE_LIMITS.api, 'circles:create', payload.userId);
  if (rateLimited) return rateLimited;

  const validated = await validateBody(request, CreateCircleSchema);
  if (validated.error) return validated.error;
  const data = validated.data as CreateCircleInput;

  try {
    const circle = await prisma.circle.create({
      data: {
        name: data.name,
        description: data.description,
        organizerId: payload.userId,
        contributionAmount: data.contributionAmount,
        contributionFrequencyDays: data.contributionFrequencyDays,
        maxRounds: data.maxRounds,
      },
      include: {
        organizer: { select: { id: true, email: true, firstName: true, lastName: true } },
        members: true,
      },
    });

    await prisma.circleMember.create({
      data: { circleId: circle.id, userId: payload.userId, rotationOrder: 1 },
    });

    return NextResponse.json({ success: true, circle }, { status: 201 });
  } catch (err) {
    console.error('Create circle error:', err);
    return NextResponse.json({ error: 'Internal server error' }, { status: 500 });
  }
}

export async function GET(request: NextRequest) {
  const token = extractToken(request.headers.get('authorization'));
  if (!token) return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });

  const payload = verifyToken(token);
  if (!payload) return NextResponse.json({ error: 'Invalid or expired token' }, { status: 401 });

  const rateLimited = applyRateLimit(request, RATE_LIMITS.api, 'circles:list', payload.userId);
  if (rateLimited) return rateLimited;

  try {
    const circles = await prisma.circle.findMany({
      where: {
        OR: [
          { organizerId: payload.userId },
          { members: { some: { userId: payload.userId } } },
        ],
      },
      include: {
        organizer: { select: { id: true, email: true, firstName: true, lastName: true } },
        members: {
          include: {
            user: { select: { id: true, email: true, firstName: true, lastName: true } },
          },
        },
        contributions: { select: { amount: true } },
      },
      orderBy: { createdAt: 'desc' },
    });

    return NextResponse.json({ success: true, circles }, { status: 200 });
  } catch (err) {
    console.error('List circles error:', err);
    return NextResponse.json({ error: 'Internal server error' }, { status: 500 });
  }
}
