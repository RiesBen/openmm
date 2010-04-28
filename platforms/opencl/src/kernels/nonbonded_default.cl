#define TILE_SIZE 32

typedef struct {
    float4 posq;
    float4 force;
    ATOM_PARAMETER_DATA
} AtomData;

/**
 * Compute nonbonded interactions.
 */

__kernel void computeNonbonded(__global float4* forceBuffers, __global float* energyBuffer, __global float4* posq, __global unsigned int* exclusions,
        __global unsigned int* exclusionIndices, __local AtomData* localData, __local float4* tempBuffer, __global unsigned int* tiles,
#ifdef USE_CUTOFF
        __global unsigned int* interactionFlags, __global unsigned int* interactionCount
#else
        unsigned int numTiles
#endif
        PARAMETER_ARGUMENTS) {
#ifdef USE_CUTOFF
    unsigned int numTiles = interactionCount[0];
#endif
    unsigned int pos = get_group_id(0)*numTiles/get_num_groups(0);
    unsigned int end = (get_group_id(0)+1)*numTiles/get_num_groups(0);
    float energy = 0.0f;
    unsigned int lasty = 0xFFFFFFFF;

    while (pos < end) {
        // Extract the coordinates of this tile
        unsigned int x = tiles[pos];
        unsigned int y = ((x >> 2) & 0x7fff)*TILE_SIZE;
        bool hasExclusions = (x & 0x1);
        x = (x>>17)*TILE_SIZE;
        unsigned int baseLocalAtom = (get_local_id(0) < TILE_SIZE ? 0 : TILE_SIZE/2);
        unsigned int tgx = get_local_id(0) & (TILE_SIZE-1);
        unsigned int forceBufferOffset = (tgx < TILE_SIZE/2 ? 0 : TILE_SIZE);
        unsigned int atom1 = x + tgx;
        float4 force = 0.0f;
        float4 posq1 = posq[atom1];
        LOAD_ATOM1_PARAMETERS
        if (x == y) {
            // This tile is on the diagonal.

            localData[get_local_id(0)].posq = posq1;
            LOAD_LOCAL_PARAMETERS_FROM_1
            barrier(CLK_LOCAL_MEM_FENCE);
            unsigned int xi = x/TILE_SIZE;
            unsigned int tile = xi+xi*PADDED_NUM_ATOMS/TILE_SIZE-xi*(xi+1)/2;
#ifdef USE_EXCLUSIONS
            unsigned int excl = exclusions[exclusionIndices[tile]+tgx] >> baseLocalAtom;
#endif
            for (unsigned int j = 0; j < TILE_SIZE/2; j++) {
#ifdef USE_EXCLUSIONS
                bool isExcluded = !(excl & 0x1);
#endif
                int atom2 = baseLocalAtom+j;
                float4 posq2 = localData[atom2].posq;
                float4 delta = (float4) (posq2.xyz - posq1.xyz, 0.0f);
#ifdef USE_PERIODIC
                delta.x -= floor(delta.x*INV_PERIODIC_BOX_SIZE_X+0.5f)*PERIODIC_BOX_SIZE_X;
                delta.y -= floor(delta.y*INV_PERIODIC_BOX_SIZE_Y+0.5f)*PERIODIC_BOX_SIZE_Y;
                delta.z -= floor(delta.z*INV_PERIODIC_BOX_SIZE_Z+0.5f)*PERIODIC_BOX_SIZE_Z;
#endif
                float r2 = delta.x*delta.x + delta.y*delta.y + delta.z*delta.z;
                float invR = native_rsqrt(r2);
                float r = native_recip(invR);
                LOAD_ATOM2_PARAMETERS
                atom2 = y+baseLocalAtom+j;
                float dEdR = 0.0f;
                float tempEnergy = 0.0f;
                COMPUTE_INTERACTION
                energy += 0.5f*tempEnergy;
                delta.xyz *= dEdR;
                force.xyz -= delta.xyz;
                excl >>= 1;
            }

            // Sum the forces and write results.

            if (get_local_id(0) >= TILE_SIZE)
                tempBuffer[get_local_id(0)] = force;
            barrier(CLK_LOCAL_MEM_FENCE);
            if (get_local_id(0) < TILE_SIZE) {
#ifdef USE_OUTPUT_BUFFER_PER_BLOCK
                unsigned int offset = x + tgx + (x/TILE_SIZE)*PADDED_NUM_ATOMS;
#else
                unsigned int offset = x + tgx + get_group_id(0)*PADDED_NUM_ATOMS;
#endif
                forceBuffers[offset].xyz = forceBuffers[offset].xyz+force.xyz+tempBuffer[get_local_id(0)+TILE_SIZE].xyz;
            }
        }
        else {
            // This is an off-diagonal tile.

            if (lasty != y && get_local_id(0) < TILE_SIZE) {
                unsigned int j = y + tgx;
                localData[get_local_id(0)].posq = posq[j];
                LOAD_LOCAL_PARAMETERS_FROM_GLOBAL
            }
            localData[get_local_id(0)].force = 0.0f;
            barrier(CLK_LOCAL_MEM_FENCE);

            // Compute the full set of interactions in this tile.

            unsigned int xi = x/TILE_SIZE;
            unsigned int yi = y/TILE_SIZE;
            unsigned int tile = xi+yi*PADDED_NUM_ATOMS/TILE_SIZE-yi*(yi+1)/2;
#ifdef USE_EXCLUSIONS
            unsigned int excl = (hasExclusions ? exclusions[exclusionIndices[tile]+tgx] : 0xFFFFFFFF);
            excl = (excl >> tgx) | (excl << (TILE_SIZE - tgx));
            excl >>= baseLocalAtom;
#endif
            unsigned int tj = tgx%(TILE_SIZE/2);
            for (unsigned int j = 0; j < TILE_SIZE/2; j++) {
#ifdef USE_EXCLUSIONS
                bool isExcluded = !(excl & 0x1);
#endif
                int atom2 = baseLocalAtom+tj;
                float4 posq2 = localData[atom2].posq;
                float4 delta = (float4) (posq2.xyz - posq1.xyz, 0.0f);
#ifdef USE_PERIODIC
                delta.x -= floor(delta.x*INV_PERIODIC_BOX_SIZE_X+0.5f)*PERIODIC_BOX_SIZE_X;
                delta.y -= floor(delta.y*INV_PERIODIC_BOX_SIZE_Y+0.5f)*PERIODIC_BOX_SIZE_Y;
                delta.z -= floor(delta.z*INV_PERIODIC_BOX_SIZE_Z+0.5f)*PERIODIC_BOX_SIZE_Z;
#endif
                float r2 = delta.x*delta.x + delta.y*delta.y + delta.z*delta.z;
                float invR = native_rsqrt(r2);
                float r = native_recip(invR);
                LOAD_ATOM2_PARAMETERS
                atom2 = y+baseLocalAtom+tj;
                float dEdR = 0.0f;
                float tempEnergy = 0.0f;
                COMPUTE_INTERACTION
                energy += tempEnergy;
                delta.xyz *= dEdR;
                force.xyz -= delta.xyz;
                localData[baseLocalAtom+tj+forceBufferOffset].force.xyz += delta.xyz;
                barrier(CLK_LOCAL_MEM_FENCE);
                excl >>= 1;
                tj = (tj+1)%(TILE_SIZE/2);
            }

            // Sum the forces and write results.

            if (get_local_id(0) >= TILE_SIZE)
                tempBuffer[get_local_id(0)] = force;
            barrier(CLK_LOCAL_MEM_FENCE);
            if (get_local_id(0) < TILE_SIZE) {
#ifdef USE_OUTPUT_BUFFER_PER_BLOCK
                unsigned int offset1 = x + tgx + (y/TILE_SIZE)*PADDED_NUM_ATOMS;
                unsigned int offset2 = y + tgx + (x/TILE_SIZE)*PADDED_NUM_ATOMS;
#else
                unsigned int offset1 = x + tgx + get_group_id(0)*PADDED_NUM_ATOMS;
                unsigned int offset2 = y + tgx + get_group_id(0)*PADDED_NUM_ATOMS;
#endif
                forceBuffers[offset1].xyz = forceBuffers[offset1].xyz+force.xyz+tempBuffer[get_local_id(0)+TILE_SIZE].xyz;
                forceBuffers[offset2].xyz = forceBuffers[offset2].xyz+localData[get_local_id(0)].force.xyz+localData[get_local_id(0)+TILE_SIZE].force.xyz;
            }
            lasty = y;
        }
        pos++;
    }
    energyBuffer[get_global_id(0)] += energy;
}
