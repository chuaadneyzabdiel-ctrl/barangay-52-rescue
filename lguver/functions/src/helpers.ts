import * as admin from 'firebase-admin';
import { onCall, HttpsError } from 'firebase-functions/v2/https';
import { onSchedule } from 'firebase-functions/v2/scheduler';

if (admin.apps.length === 0) {
  admin.initializeApp();
}

const db = admin.firestore();
const { FieldValue, Timestamp } = admin.firestore;

type Role = 'citizen' | 'responder' | 'lgu';
type SosStatus = 'pending' | 'accepted' | 'completed' | 'cancelled';
type ResponseAction = 'completed' | 'cancelled';
type LatLng = { lat: number; lng: number };

const PH = {
  MIN_LAT: 4.0,
  MAX_LAT: 21.0,
  MIN_LNG: 116.0,
  MAX_LNG: 127.0,
};

function assertNonEmptyTrimmed(value: string, min: number, max: number, field: string) {
  if (typeof value !== 'string') {
    throw new HttpsError('invalid-argument', `${field}_INVALID`);
  }
  const v = value.trim();
  if (v.length < min || v.length > max) {
    throw new HttpsError('invalid-argument', `${field}_INVALID`);
  }
}

function assertValidPhilLocation(location: LatLng) {
  if (!location || typeof location.lat !== 'number' || typeof location.lng !== 'number') {
    throw new HttpsError('invalid-argument', 'INVALID_LOCATION');
  }
  if (
    location.lat < PH.MIN_LAT ||
    location.lat > PH.MAX_LAT ||
    location.lng < PH.MIN_LNG ||
    location.lng > PH.MAX_LNG
  ) {
    throw new HttpsError('invalid-argument', 'OUT_OF_PH_RANGE');
  }
}

function startOfTodayUtc() {
  const now = new Date();
  return new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate(), 0, 0, 0, 0));
}

async function requireRole(userId: string, role: Role) {
  const userSnap = await db.collection('users').doc(userId).get();
  if (!userSnap.exists) {
    throw new HttpsError('permission-denied', 'USER_NOT_FOUND');
  }
  if (userSnap.get('role') !== role) {
    throw new HttpsError('permission-denied', 'ROLE_FORBIDDEN');
  }
}

// 10) logAudit
export async function logAudit(
  action: string,
  performedBy: string,
  targetId: string,
  details: Record<string, unknown>
): Promise<void> {
  await db.collection('auditLogs').add({
    action,
    performedBy,
    targetId,
    details,
    timestamp: FieldValue.serverTimestamp(),
  });
}

// 1) canGuestSendSOS(deviceId: string): Promise<{allowed: boolean, reason?: string}>
export async function canGuestSendSOS(
  deviceId: string
): Promise<{ allowed: boolean; reason?: 'BANNED' | 'COOLDOWN' | 'DAILY_CAP_REACHED' }> {
  const guestRef = db.collection('guests').doc(deviceId);
  const guestSnap = await guestRef.get();
  if (!guestSnap.exists) {
    return { allowed: true };
  }

  const data = guestSnap.data()!;
  if (data.isBanned === true) {
    return { allowed: false, reason: 'BANNED' };
  }

  const lastSosAt = data.lastSosAt as admin.firestore.Timestamp | undefined;
  let sosCount = typeof data.sosCount === 'number' ? data.sosCount : 0;

  if (lastSosAt) {
    const today = startOfTodayUtc();
    if (lastSosAt.toDate() < today) {
      sosCount = 0;
    }
  }

  if (sosCount >= 3) {
    return { allowed: false, reason: 'DAILY_CAP_REACHED' };
  }

  if (lastSosAt) {
    const elapsedMs = Date.now() - lastSosAt.toMillis();
    if (elapsedMs < 60_000) {
      return { allowed: false, reason: 'COOLDOWN' };
    }
  }

  return { allowed: true };
}

// 2) sendSOS(...)
export async function sendSOS(payload: {
  deviceId: string;
  userId?: string;
  isGuest: boolean;
  location: { lat: number; lng: number };
  guestName?: string;
}): Promise<string> {
  const { deviceId, userId, isGuest, location, guestName } = payload;
  if (!deviceId || typeof deviceId !== 'string') {
    throw new HttpsError('invalid-argument', 'INVALID_DEVICE_ID');
  }
  assertValidPhilLocation(location);

  if (guestName !== undefined) {
    assertNonEmptyTrimmed(guestName, 1, 100, 'GUEST_NAME');
  }

  if (isGuest) {
    const res = await canGuestSendSOS(deviceId);
    if (!res.allowed) {
      throw new HttpsError('failed-precondition', res.reason ?? 'GUEST_REJECTED');
    }
  } else {
    if (!userId) throw new HttpsError('unauthenticated', 'AUTH_REQUIRED');
    await requireRole(userId, 'citizen');

    const activeSnap = await db
      .collection('sos')
      .where('citizenId', '==', userId)
      .where('status', 'in', ['pending', 'accepted'])
      .limit(1)
      .get();
    if (!activeSnap.empty) {
      throw new HttpsError('failed-precondition', 'HAS_ACTIVE_SOS');
    }
  }

  const sosRef = db.collection('sos').doc();

  await db.runTransaction(async (tx) => {
    tx.set(sosRef, {
      citizenId: isGuest ? null : userId!,
      deviceId,
      guestName: isGuest ? (guestName?.trim() ?? null) : null,
      isGuest,
      location,
      status: 'pending' as SosStatus,
      cancelReason: null,
      cancelledAfterDispatch: false,
      assignedResponderId: null,
      createdAt: FieldValue.serverTimestamp(),
      resolvedAt: null,
    });

    if (isGuest) {
      const guestRef = db.collection('guests').doc(deviceId);
      const guestSnap = await tx.get(guestRef);
      const nowTs = FieldValue.serverTimestamp();
      if (!guestSnap.exists) {
        tx.set(guestRef, {
          deviceId,
          sosCount: 1,
          lastSosAt: nowTs,
          strikes: 0,
          isBanned: false,
          bannedAt: null,
          banReason: null,
          guestName: guestName?.trim() ?? null,
        });
      } else {
        const g = guestSnap.data()!;
        const lastSosAt = g.lastSosAt as admin.firestore.Timestamp | undefined;
        let sosCount = typeof g.sosCount === 'number' ? g.sosCount : 0;
        if (lastSosAt && lastSosAt.toDate() < startOfTodayUtc()) {
          sosCount = 0;
        }
        sosCount += 1;
        if (sosCount > 3) {
          throw new HttpsError('failed-precondition', 'DAILY_CAP_REACHED');
        }
        tx.update(guestRef, {
          sosCount,
          lastSosAt: nowTs,
          ...(guestName ? { guestName: guestName.trim() } : {}),
        });
      }
    }
  });

  return sosRef.id;
}

// 3) cancelSOS(...)
export async function cancelSOS(
  sosId: string,
  reason: string,
  cancelledBy: { userId?: string; deviceId?: string }
): Promise<void> {
  assertNonEmptyTrimmed(reason, 10, 1000, 'CANCEL_REASON');
  if (!cancelledBy.userId && !cancelledBy.deviceId) {
    throw new HttpsError('invalid-argument', 'MISSING_CANCELLED_BY');
  }

  const sosRef = db.collection('sos').doc(sosId);

  await db.runTransaction(async (tx) => {
    const sosSnap = await tx.get(sosRef);
    if (!sosSnap.exists) {
      throw new HttpsError('not-found', 'SOS_NOT_FOUND');
    }
    const sos = sosSnap.data()!;
    const isOwnerByUser = Boolean(cancelledBy.userId && sos.citizenId === cancelledBy.userId);
    const isOwnerByDevice = Boolean(cancelledBy.deviceId && sos.deviceId === cancelledBy.deviceId);
    if (!isOwnerByUser && !isOwnerByDevice) {
      throw new HttpsError('permission-denied', 'NOT_SOS_OWNER');
    }
    if (!['pending', 'accepted'].includes(sos.status)) {
      throw new HttpsError('failed-precondition', 'SOS_NOT_CANCELLABLE');
    }

    const cancelledAfterDispatch = Boolean(sos.assignedResponderId);
    tx.update(sosRef, {
      status: 'cancelled',
      cancelReason: reason.trim(),
      cancelledAfterDispatch,
      resolvedAt: FieldValue.serverTimestamp(),
    });

    if (sos.isGuest === true && cancelledAfterDispatch) {
      const guestRef = db.collection('guests').doc(sos.deviceId);
      const guestSnap = await tx.get(guestRef);
      const currentStrikes = guestSnap.exists ? Number(guestSnap.get('strikes') ?? 0) : 0;
      const strikes = Math.min(3, currentStrikes + 1);
      const shouldBan = strikes >= 3;

      tx.set(
        guestRef,
        {
          deviceId: sos.deviceId,
          strikes,
          isBanned: shouldBan,
          ...(shouldBan
            ? {
                bannedAt: FieldValue.serverTimestamp(),
                banReason: '3 false alarms (cancelled after dispatch)',
              }
            : {}),
        },
        { merge: true }
      );

      if (shouldBan) {
        const auditRef = db.collection('auditLogs').doc();
        tx.set(auditRef, {
          action: 'AUTO_BAN_GUEST',
          performedBy: cancelledBy.userId ?? cancelledBy.deviceId ?? 'system',
          targetId: sos.deviceId,
          details: { sosId, strikes },
          timestamp: FieldValue.serverTimestamp(),
        });
      }
    }
  });
}

// 4) goOnline(...)
export async function goOnline(responderId: string, location: LatLng): Promise<void> {
  assertValidPhilLocation(location);

  const responderRef = db.collection('responders').doc(responderId);
  const responderSnap = await responderRef.get();
  if (!responderSnap.exists) {
    throw new HttpsError('not-found', 'RESPONDER_NOT_FOUND');
  }
  if (responderSnap.get('approvedByLgu') !== true) {
    throw new HttpsError('permission-denied', 'RESPONDER_NOT_APPROVED');
  }

  await responderRef.update({
    isOnline: true,
    currentLocation: location,
    lastHeartbeatAt: FieldValue.serverTimestamp(),
  });
}

// 5) acceptDispatch(...)
export async function acceptDispatch(responderId: string, sosId: string): Promise<void> {
  const responderRef = db.collection('responders').doc(responderId);
  const sosRef = db.collection('sos').doc(sosId);

  await db.runTransaction(async (tx) => {
    const [responderSnap, sosSnap] = await Promise.all([tx.get(responderRef), tx.get(sosRef)]);
    if (!responderSnap.exists) throw new HttpsError('not-found', 'RESPONDER_NOT_FOUND');
    if (!sosSnap.exists) throw new HttpsError('not-found', 'SOS_NOT_FOUND');

    if (responderSnap.get('approvedByLgu') !== true) {
      throw new HttpsError('permission-denied', 'RESPONDER_NOT_APPROVED');
    }
    if (responderSnap.get('activeSosId')) {
      throw new HttpsError('failed-precondition', 'RESPONDER_ALREADY_HAS_ACTIVE_SOS');
    }
    if (sosSnap.get('status') !== 'pending') {
      throw new HttpsError('failed-precondition', 'SOS_NOT_PENDING');
    }

    tx.update(responderRef, {
      activeSosId: sosId,
      lastHeartbeatAt: FieldValue.serverTimestamp(),
    });
    tx.update(sosRef, {
      status: 'accepted' as SosStatus,
      assignedResponderId: responderId,
    });
  });
}

// 6) heartbeat(...)
export async function heartbeat(responderId: string, location: LatLng): Promise<void> {
  assertValidPhilLocation(location);
  await db.collection('responders').doc(responderId).update({
    currentLocation: location,
    lastHeartbeatAt: FieldValue.serverTimestamp(),
  });
}

// 7) completeOrCancelResponse(...)
export async function completeOrCancelResponse(
  responderId: string,
  sosId: string,
  action: ResponseAction,
  reason: string
): Promise<void> {
  assertNonEmptyTrimmed(reason, 1, 1000, 'RESPONSE_REASON');

  const responderRef = db.collection('responders').doc(responderId);
  const sosRef = db.collection('sos').doc(sosId);

  await db.runTransaction(async (tx) => {
    const [responderSnap, sosSnap] = await Promise.all([tx.get(responderRef), tx.get(sosRef)]);
    if (!responderSnap.exists) throw new HttpsError('not-found', 'RESPONDER_NOT_FOUND');
    if (!sosSnap.exists) throw new HttpsError('not-found', 'SOS_NOT_FOUND');

    const activeSosId = responderSnap.get('activeSosId');
    const assignedResponderId = sosSnap.get('assignedResponderId');
    if (activeSosId !== sosId || assignedResponderId !== responderId) {
      throw new HttpsError('permission-denied', 'RESPONDER_NOT_ASSIGNED_TO_SOS');
    }

    tx.update(sosRef, {
      status: action as SosStatus,
      ...(action === 'cancelled' ? { cancelReason: reason.trim() } : {}),
      resolvedAt: FieldValue.serverTimestamp(),
    });
    tx.update(responderRef, {
      activeSosId: null,
      lastHeartbeatAt: FieldValue.serverTimestamp(),
    });

    const auditRef = db.collection('auditLogs').doc();
    tx.set(auditRef, {
      action: action === 'completed' ? 'RESPONDER_COMPLETED_SOS' : 'RESPONDER_CANCELLED_SOS',
      performedBy: responderId,
      targetId: sosId,
      details: { reason: reason.trim() },
      timestamp: FieldValue.serverTimestamp(),
    });
  });
}

// 8) createResponder(...)
export async function createResponder(payload: {
  userId: string;
  unitName: string;
  name: string;
}): Promise<void> {
  const { userId, unitName, name } = payload;
  assertNonEmptyTrimmed(unitName, 1, 50, 'UNIT_NAME');
  assertNonEmptyTrimmed(name, 1, 100, 'NAME');
  const unit = unitName.trim();

  const existing = await db.collection('responders').where('unitName', '==', unit).limit(1).get();
  if (!existing.empty) {
    throw new HttpsError('already-exists', 'UNIT_NAME_ALREADY_EXISTS');
  }

  await db.runTransaction(async (tx) => {
    tx.set(
      db.collection('users').doc(userId),
      {
        role: 'responder',
        name: name.trim(),
        updatedAt: FieldValue.serverTimestamp(),
      },
      { merge: true }
    );

    tx.set(db.collection('responders').doc(userId), {
      unitName: unit,
      isOnline: false,
      currentLocation: null,
      lastHeartbeatAt: null,
      activeSosId: null,
      approvedByLgu: false,
    });

  });
}

// 9) approveResponder(...)
export async function approveResponder(responderId: string, lguId: string): Promise<void> {
  await requireRole(lguId, 'lgu');
  await db.collection('responders').doc(responderId).update({
    approvedByLgu: true,
  });
  await logAudit('APPROVE_RESPONDER', lguId, responderId, { approvedByLgu: true });
}

export const sendSOSCallable = onCall(async (req) => {
  const payload = req.data as {
    deviceId: string;
    userId?: string;
    isGuest: boolean;
    location: { lat: number; lng: number };
    guestName?: string;
  };
  // For registered user, bind to Firebase Auth context.
  const userIdFromAuth = req.auth?.uid;
  const effectiveUserId = payload.isGuest ? undefined : (userIdFromAuth ?? payload.userId);
  const sosId = await sendSOS({ ...payload, userId: effectiveUserId });
  return { sosId };
});

export const cancelSOSCallable = onCall(async (req) => {
  const { sosId, reason, deviceId } = req.data as {
    sosId: string;
    reason: string;
    deviceId?: string;
  };
  await cancelSOS(sosId, reason, { userId: req.auth?.uid, deviceId });
  return { ok: true };
});

export const heartbeatAutoOffline = onSchedule('every 30 seconds', async () => {
  const cutoff = Timestamp.fromMillis(Date.now() - 30_000);
  const stale = await db
    .collection('responders')
    .where('isOnline', '==', true)
    .where('lastHeartbeatAt', '<', cutoff)
    .get();

  if (stale.empty) return;

  const batch = db.batch();
  stale.docs.forEach((doc) => {
    batch.update(doc.ref, { isOnline: false });
  });
  await batch.commit();
});
