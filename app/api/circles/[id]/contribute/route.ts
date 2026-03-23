import { NextRequest, NextResponse } from 'next/server';
import { prisma } from '@/lib/prisma';
import { verifyToken, extractToken } from '@/lib/auth';
import { validateBody, applyRateLimit } from '@/lib/api-helpers';
import { ContributeSchema } from '@/lib/validations/circle';
import { RATE_LIMITS } from '@/lib/rate-limit';

export async function POST(
  request: NextRequest,
  { params }: { params: Promise<{ id: string }> },
) {
  const token = extractToken(request.headers.get('authorization'));
  if (!token) return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });

  const payload = verifyToken(token);
  if (!payload) return NextResponse.json({ error: 'Invalid or expired token' }, { status: 401 });

  const rateLimited = applyRateLimit(request, RATE_LIMITS.api, 'circles:contribute', payload.userId);
  if (rateLimited) return rateLimited;

  const { data, error } = await validateBody(request, ContributeSchema);
  if (error) return error;

  try {
    const { id } = await params;

    const circle = await prisma.circle.findUnique({ where: { id } });
    if (!circle) return NextResponse.json({ error: 'Circle not found' }, { status: 404 });

    const member = await prisma.circleMember.findUnique({
      where: { circleId_userId: { circleId: id, userId: payload.userId } },
    });

    if (!member) {
      return NextResponse.json({ error: 'You are not a member of this circle' }, { status: 403 });
    }

    const contribution = await prisma.contribution.create({
      data: {
        circleId: id,
        userId: payload.userId,
        amount: data.amount,
        round: circle.currentRound,
        status: 'COMPLETED',
      },
      include: { user: { select: { id: true, firstName: true, lastName: true } } },
    });

    await prisma.circleMember.update({
      where: { circleId_userId: { circleId: id, userId: payload.userId } },
      data: { totalContributed: { increment: data.amount } },
    });

    return NextResponse.json({ success: true, contribution }, { status: 201 });
  } catch (err) {
    console.error('Contribute error:', err);
    return NextResponse.json({ error: 'Internal server error' }, { status: 500 });
  }
}
