import { z } from 'zod';

export const UpdateProfileSchema = z.object({
  firstName: z.string().min(2).max(50).optional(),
  lastName: z.string().min(2).max(50).optional(),
  bio: z.string().max(160).optional(),
  phoneNumber: z.string().max(20).optional(),
});

export const UpdateWalletSchema = z.object({
  walletAddress: z.string().min(1, 'Wallet address is required'),
});

export type UpdateProfileInput = z.infer<typeof UpdateProfileSchema>;
export type UpdateWalletInput = z.infer<typeof UpdateWalletSchema>;
