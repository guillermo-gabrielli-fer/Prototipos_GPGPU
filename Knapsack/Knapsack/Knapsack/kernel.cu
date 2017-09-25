#include "cuda.h"
#include "cuda_runtime.h"
#include <device_functions.h>
#include "device_launch_parameters.h"
#include "curand.h"
#include "curand_kernel.h"
#include <ctime>
#include <stdio.h>
#include "notbitwise.cuh"
#include "stdint.h"
#include "ErrorInfo.h"
#include "bitwise.cuh"
#include <ctime>
#include <iostream>


#ifdef __INTELLISENSE__

//for __syncthreads()
#ifndef __CUDACC_RTC__ 
#define __CUDACC_RTC__
#endif // !(__CUDACC_RTC__)
//for atomicAdd
#ifndef __CUDACC__
#define __CUDACC__
#endif // !__CUDACC__

#define __DEVICE_FUNCTIONS_H__

#endif


#define makeRandomInts makeRandomIntegers2

struct EvalInfo {
	float min;
	float minValido;
	float max;
	float avg;
	float avgValido;
	float avgPenal;
	int invalidos;
};

template<typename T>
__global__ void sumar(T* dev_rnd, float* dev_output,unsigned int len)
{
	__shared__ float intermedio[MAX_THREADS_PER_BLOCK];
	unsigned int idx = blockIdx.x * blockDim.x + threadIdx.x;
	unsigned int tid = threadIdx.x;
	intermedio[threadIdx.x] = idx < len ?  dev_rnd[idx] : 0;
	__syncthreads();
	for (unsigned int s = blockDim.x / 2; s != 0; s >>= 1) {
		if (tid < s) {
			intermedio[tid] += intermedio[tid + s];
		}
		__syncthreads();
	}
	__syncthreads();
	if (threadIdx.x == 0) {
		dev_output[blockIdx.x] = intermedio[0];
	}
}


/*template<typename T>
__global__ void contarInvalidos(T* fitness, float* dev_output, unsigned int pop_size)
{
	__shared__ float intermedio[MAX_THREADS_PER_BLOCK];
	unsigned int idx = blockIdx.x * blockDim.x + threadIdx.x;
	unsigned int tid = threadIdx.x;
	intermedio[threadIdx.x] = idx < pop_size ? 1 : 0;
	__syncthreads();
	for (unsigned int s = blockDim.x / 2; s != 0; s >>= 1) {
		if (tid < s) {
			intermedio[tid] += intermedio[tid + s];
		}
		__syncthreads();
	}
	__syncthreads();
	if (threadIdx.x == 0) {
		dev_output[blockIdx.x] = intermedio[0];
	}
}*/



// sumar mas optimizado pero mas rigido
/*__global__ void sumar2(float* dev_rnd, float* dev_output)
{
	extern __shared__ float intermedio[];
	unsigned int idx = blockIdx.x * blockDim.x * 2 + threadIdx.x;
	unsigned int tid = threadIdx.x;
	intermedio[threadIdx.x] = dev_rnd[idx] + dev_rnd[idx + blockDim.x];
	__syncthreads();
	for (unsigned int s = blockDim.x / 2; s != 0; s >>= 1) {
		if (tid < s) {
			intermedio[tid] += intermedio[tid + s];
		}
		__syncthreads();
	}
	__syncthreads();
	if (threadIdx.x == 0) {
		dev_output[blockIdx.x] = intermedio[0];
	}
}*/

__global__ void minimo(float* dev_rnd, float* dev_output,unsigned int len)
{
	__shared__ float intermedio[MAX_THREADS_PER_BLOCK];
	unsigned int idx = blockIdx.x * blockDim.x + threadIdx.x;
	unsigned int tid = threadIdx.x;
	intermedio[threadIdx.x] = idx < len ? dev_rnd[idx] : dev_rnd[0];
	__syncthreads();
	for (unsigned int s = blockDim.x / 2; s != 0; s >>= 1) {
		if (tid < s) {
			intermedio[tid] = min(intermedio[tid], intermedio[tid + s]);
		}
		__syncthreads();
	}
	__syncthreads();
	if (threadIdx.x == 0) {
		dev_output[blockIdx.x] = intermedio[0];
	}
}

__global__ void maximo(float* dev_rnd, float* dev_output, unsigned int len)
{
	__shared__ float intermedio[MAX_THREADS_PER_BLOCK];
	unsigned int idx = blockIdx.x * blockDim.x + threadIdx.x;
	unsigned int tid = threadIdx.x;
	intermedio[threadIdx.x] = idx < len ? dev_rnd[idx] : dev_rnd[0];
	__syncthreads();
	for (unsigned int s = blockDim.x / 2; s != 0; s >>= 1) {
		if (tid < s) {
			intermedio[tid] = max(intermedio[tid], intermedio[tid + s]);
		}
		__syncthreads();
	}
	__syncthreads();
	if (threadIdx.x == 0) {
		dev_output[blockIdx.x] = intermedio[0];
	}
}

__global__ void contarInvalidos(float* fitness, float* dev_output, size_t pop_size) {
	__shared__ float intermedio[MAX_THREADS_PER_BLOCK];
	unsigned int tid = threadIdx.x;
	intermedio[tid] = 0;
	for (int i = tid; i < pop_size; i += MAX_THREADS_PER_BLOCK) {
		intermedio[tid] += (fitness[i] < 0) ? 1 : 0;
	}
	// reduction algorithm to add the partial fitness values
	__syncthreads();
	int i = MAX_THREADS_PER_BLOCK / 2;
	while (i != 0) {
		if (threadIdx.x < i)
			intermedio[threadIdx.x] = intermedio[threadIdx.x] + intermedio[threadIdx.x + i];
		__syncthreads();
		i = i / 2;
	}

	// finally thread 0 writes the fitness value in global memory
	if (threadIdx.x == 0)
		dev_output[blockIdx.x] = intermedio[0];
}

__global__ void sumarValidez(float* fitness, float* dev_output, size_t pop_size) {
	__shared__ float intermedio_val[MAX_THREADS_PER_BLOCK];
	__shared__ float intermedio_inval[MAX_THREADS_PER_BLOCK];
	__shared__ float intermedio_cant[MAX_THREADS_PER_BLOCK];
	unsigned int tid = threadIdx.x;
	intermedio_val[tid] = 0;
	intermedio_inval[tid] = 0;
	intermedio_cant[tid] = 0;
	for (int i = tid; i < pop_size; i += MAX_THREADS_PER_BLOCK) {
		if (fitness[i]  >= 0 ) {
			intermedio_val[tid] +=  fitness[i];
		}
		else {
			intermedio_inval[tid] += fitness[i];
			intermedio_cant[tid] += 1;
		}
		
	}
	// reduction algorithm to add the partial fitness values
	__syncthreads();
	int i = MAX_THREADS_PER_BLOCK / 2;
	while (i != 0) {
		if (threadIdx.x < i)
			intermedio_val[threadIdx.x] = intermedio_val[threadIdx.x] + intermedio_val[threadIdx.x + i];
		__syncthreads();
		i = i / 2;
	}

	// reduction algorithm to add the partial fitness values
	__syncthreads();
	 i = MAX_THREADS_PER_BLOCK / 2;
	while (i != 0) {
		if (threadIdx.x < i)
			intermedio_inval[threadIdx.x] = intermedio_inval[threadIdx.x] + intermedio_inval[threadIdx.x + i];
		__syncthreads();
		i = i / 2;
	}

	// reduction algorithm to add the partial fitness values
	__syncthreads();
	 i = MAX_THREADS_PER_BLOCK / 2;
	while (i != 0) {
		if (threadIdx.x < i)
			intermedio_cant[threadIdx.x] = intermedio_cant[threadIdx.x] + intermedio_cant[threadIdx.x + i];
		__syncthreads();
		i = i / 2;
	}

	// finally thread 0 writes the fitness value in global memory
	if (threadIdx.x == 0) {
		dev_output[0] = intermedio_cant[0]; // cant invalidos
		dev_output[1] = intermedio_inval[0]; // suma invalidos 
		dev_output[2] = intermedio_val[0]; // suma validos

	}
		
}

__global__ void minimoValidos(float* fitness, float* dev_output, size_t pop_size) {
	__shared__ float intermedio[MAX_THREADS_PER_BLOCK];
	unsigned int tid = threadIdx.x;
	intermedio[tid] = 0;
	for (int i = tid; i < pop_size; i += MAX_THREADS_PER_BLOCK) {
		if (fitness[i] > 0) {
			intermedio[tid] = intermedio[tid] > 0 ? min(intermedio[tid], fitness[i]) : fitness[i];
		}
	}
	// reduction algorithm to add the partial fitness values
	__syncthreads();
	int i = MAX_THREADS_PER_BLOCK / 2;
	while (i != 0) {
		if (threadIdx.x < i){
			if (intermedio[threadIdx.x] > 0 && intermedio[threadIdx.x + i] > 0) {
				// el menor de los valores > 0
				intermedio[threadIdx.x] = min(intermedio[threadIdx.x], intermedio[threadIdx.x + i]);
			}
			else {
				// el mayor de los dos valores (el mayor a 0 o 0 si los 2 son 0)
				intermedio[threadIdx.x] = max(intermedio[threadIdx.x], intermedio[threadIdx.x + i]);
			}
			
		}
		__syncthreads();
		i = i / 2;
	}

	// finally thread 0 writes the fitness value in global memory
	if (threadIdx.x == 0)
		dev_output[blockIdx.x] = intermedio[0];
}




__global__ void scaleRandom(float* floatRnd, int* intRnd, size_t N, unsigned int scale) {
	unsigned int pos = blockIdx.x * blockDim.x + threadIdx.x;
	if (pos < N) {
		intRnd[pos] = __float2int_rd(floatRnd[pos] * (scale + 0.999999f));
	}

}


ErrorInfo makeRandomIntegers(curandGenerator_t& generator, int* indices, unsigned int N, unsigned int max) {
	ErrorInfo status;
	float* rndFloat;

	status.cuda = cudaMalloc(&rndFloat, N * sizeof(float));
	if (status.failed()) return status;

	status.curand = curandGenerateUniform(generator, rndFloat, N);
	status.cuda = cudaDeviceSynchronize();
	if(status.failed()) return status;

	unsigned int blocks = (N + MAX_THREADS_PER_BLOCK - 1) / MAX_THREADS_PER_BLOCK; // ceil(N/MAX_THREADS_PER_BLOCK)
	scaleRandom << <blocks, MAX_THREADS_PER_BLOCK >> >(rndFloat, indices, N, max);
	status.cuda = cudaGetLastError();
	if (status.failed()) return status;

	status.cuda = cudaDeviceSynchronize();

	cudaFree(rndFloat);
	return status;

}


__global__ void scaleRandom2(uint32_t* rnd,  size_t N, double scale) {
	unsigned int pos = blockIdx.x * blockDim.x + threadIdx.x;
	if (pos < N) {
		// multiplicar aleatorio por escala, mul
		rnd[pos] = __double2uint_rd(__dmul_rd (rnd[pos] , scale));
	}

}

__global__ void scaleRandomMod(uint32_t* rnd, size_t N, uint32_t max1) {
	unsigned int pos = blockIdx.x * blockDim.x + threadIdx.x;
	if (pos < N) {
		rnd[pos] = rnd[pos] % max1;
	}

}



ErrorInfo makeRandomIntegers2(curandGenerator_t& generator, int32_t* indices, unsigned int N, unsigned int max) {
	ErrorInfo status;
	uint32_t* uindices = (uint32_t*)indices; // reinterpreto indices como si fueran unsigned
	double scale = (double)(max + (1 - 1e-6)) / ((1LL << 32) - 1) ;

	status.curand = curandGenerate(generator, uindices, N);
	status.cuda = cudaDeviceSynchronize();
	if (status.failed()) return status;

	unsigned int blocks = (N + MAX_THREADS_PER_BLOCK - 1) / MAX_THREADS_PER_BLOCK; // ceil(N/MAX_THREADS_PER_BLOCK)
	scaleRandom2 << <blocks, MAX_THREADS_PER_BLOCK >> >( uindices, N, scale);
	status.cuda = cudaGetLastError();
	if (status.failed()) return status;

	status.cuda = cudaDeviceSynchronize();

	return status;

}

ErrorInfo makeRandomIntegersMod(curandGenerator_t& generator, int32_t* indices, unsigned int N, unsigned int max) {
	ErrorInfo status;
	uint32_t* uindices = (uint32_t*)indices; // reinterpreto indices como si fueran unsigned

	status.curand = curandGenerate(generator, uindices, N);
	status.cuda = cudaDeviceSynchronize();
	if (status.failed()) return status;

	unsigned int blocks = (N + MAX_THREADS_PER_BLOCK - 1) / MAX_THREADS_PER_BLOCK; // ceil(N/MAX_THREADS_PER_BLOCK)
	scaleRandomMod << <blocks, MAX_THREADS_PER_BLOCK >> >(uindices, N, max+1);
	status.cuda = cudaGetLastError();
	if (status.failed()) return status;

	status.cuda = cudaDeviceSynchronize();

	return status;

}



curandStatus_t initGenerator(curandGenerator_t& generator ,unsigned long long seed) {
	curandStatus_t s =  curandCreateGenerator(&generator, CURAND_RNG_PSEUDO_PHILOX4_32_10);
	if (s != CURAND_STATUS_SUCCESS) {
		return s; 
	}
	s = curandSetPseudoRandomGeneratorSeed(generator,seed);
	return s;
}

ErrorInfo initProbs(float** probs, int** points, size_t POP_SIZE) {
	ErrorInfo status;
	status.cuda = cudaMalloc(probs, POP_SIZE * sizeof(float));
	if (status.failed()) return status;
	status.cuda = cudaMalloc(points, POP_SIZE * sizeof(int));
	return status;
}

ErrorInfo makeRandomNumbersMutation(curandGenerator_t& generator, size_t POP_SIZE, int len, float* randomPM, int* randomPoint) {
	ErrorInfo status; 

	status.curand = curandGenerateUniform(generator, randomPM, POP_SIZE);
	if (status.failed()) return status;

	status = makeRandomInts(generator, randomPoint, POP_SIZE, len - 1);
	if (status.failed()) return status;
	status.cuda = cudaDeviceSynchronize();

	return status;

}



ErrorInfo makeRandomNumbersSpx(curandGenerator_t& generator, size_t POP_SIZE, int len, float* randomPC, int* randomPoint) {
	ErrorInfo status;
	size_t HALF_SIZE = POP_SIZE / 2;

	status = makeRandomInts(generator, randomPoint, HALF_SIZE, len - 1);
	if (status.failed()) return status;

	status.curand = curandGenerateUniform(generator, randomPC, HALF_SIZE);
	status.cuda = cudaDeviceSynchronize();

	return status;

}

ErrorInfo makeRandomNumbersDpx(curandGenerator_t& generator, size_t POP_SIZE, int len, float* randomPC, int* randomPoint) {
	ErrorInfo status;
	size_t HALF_SIZE = POP_SIZE / 2;

	status = makeRandomInts(generator, randomPoint, POP_SIZE, len - 1);
	if (status.failed()) return status;

	status.curand = curandGenerateUniform(generator, randomPC, HALF_SIZE);
	status.cuda = cudaDeviceSynchronize();

	return status;

}

cudaError_t InitTournRandom( int** random, size_t POP_SIZE) {
	return cudaMalloc(random, 2 * sizeof( int) * POP_SIZE);
}



ErrorInfo makeRandomNumbersTournement(curandGenerator_t& generator, size_t POP_SIZE, int* random) {
	// generar (POPSIZE * 2) numeros aleatorios enteros de 0 a POPSIZE - 1
	return makeRandomInts(generator, random, POP_SIZE * 2, POP_SIZE - 1);
}

cudaError_t InitFit(float** dev_fit,size_t POP_SIZE) {
	return cudaMalloc(dev_fit, sizeof(float) * POP_SIZE);
}
cudaError_t InitWin(int** dev_win, size_t POP_SIZE) {
	return cudaMalloc(dev_win, sizeof(int) * POP_SIZE );
}

int cantInvalidosHost(float* fitness, size_t SIZE) {
	int total = 0;
	for (int i = 0; i < SIZE; i++) {
		total += fitness[i] < 0 ? 1 : 0;
	}
	return total;
}

// evaluate comun
ErrorInfo evaluate_(size_t POP_SIZE, float* dev_fit, EvalInfo& eval) {

	ErrorInfo status;
	float avgFit, avgFitVal, minFitVal;
	T_FIT minFit, maxFit;
	float cantInv;
	float host_stats[3];
	size_t STAT_SIZE = sizeof(float) * 3;
	//cudaMallocHost(&host_stats, STAT_SIZE);

	status.cuda = cudaGetLastError();
	if (status.failed()) return status;

	status.cuda = cudaDeviceSynchronize();
	if (status.failed()) return status;


	float* out1;
	float* out2;
	float* out3;

	int nroBlocks = (POP_SIZE + MAX_THREADS_PER_BLOCK - 1) / (MAX_THREADS_PER_BLOCK);
	cudaMalloc(&out1, nroBlocks * sizeof(float));
	cudaMalloc(&out2, nroBlocks * sizeof(float));
	cudaMalloc(&out3, STAT_SIZE);

	// hallar minimo
	minimo << <nroBlocks, MAX_THREADS_PER_BLOCK >> >(dev_fit, out1, POP_SIZE);
	minimo << <1, MAX_THREADS_PER_BLOCK >> >(out1, out1, nroBlocks);
	cudaMemcpy(&minFit, out1, sizeof(T_FIT), cudaMemcpyDeviceToHost);

	// hallar maximo
	maximo << <nroBlocks, MAX_THREADS_PER_BLOCK >> >(dev_fit, out1, POP_SIZE);
	maximo << <1, MAX_THREADS_PER_BLOCK >> >(out1, out1, nroBlocks);
	cudaMemcpy(&maxFit, out1, sizeof(T_FIT), cudaMemcpyDeviceToHost);

	// promedio
	sumar << <nroBlocks, MAX_THREADS_PER_BLOCK >> >(dev_fit, out2, POP_SIZE);
	sumar << <1, MAX_THREADS_PER_BLOCK >> >(out2, out2, nroBlocks);
	cudaMemcpy(&avgFit, out2, sizeof(float), cudaMemcpyDeviceToHost);


	// contar Invalidos
	/*contarInvalidos << <1, MAX_THREADS_PER_BLOCK >> >(dev_fit, out2, POP_SIZE);
	cudaMemcpy(&cantInv, out2, sizeof(float), cudaMemcpyDeviceToHost);
	eval.invalidos = cantInv;*/

	// cant invalidos, promedio validos e invalidos
	sumarValidez << <1, MAX_THREADS_PER_BLOCK >> >(dev_fit, out3, POP_SIZE);
	cudaMemcpy(&host_stats, out3, STAT_SIZE, cudaMemcpyDeviceToHost);
	eval.invalidos = host_stats[0];
	eval.avgPenal = eval.invalidos > 0 ? host_stats[1] / eval.invalidos : 0;
	eval.avgValido = eval.invalidos < POP_SIZE ? host_stats[2] / (POP_SIZE - eval.invalidos) : 0;
	//cudaFreeHost(host_stats);

	// minimo validos
	minimoValidos << <1, MAX_THREADS_PER_BLOCK >> >(dev_fit, out2, POP_SIZE);
	cudaMemcpy(&minFitVal, out2, sizeof(float), cudaMemcpyDeviceToHost);
	eval.minValido = minFitVal;

	status.cuda = cudaGetLastError();
	if (status.failed()) return status;

	status.cuda = cudaDeviceSynchronize();
	if (status.failed()) return status;


	cudaFree(out1);
	cudaFree(out2);
	cudaFree(out3);

	avgFit = (avgFit / POP_SIZE);// / length;
	eval.min = minFit; /// (double)length;
	eval.max = maxFit;// / (double)length;
	eval.avg = avgFit;
	//eval.invalidos = (int)cantInv;
	//if (SALIDA) printf("Min: %f, Max: %f, Avg: %f\n", minFit / (double)length,maxFit / (double) length, avgFit);

	return status;

}


ErrorInfo evaluate(bool* pop, size_t POP_SIZE, int length,float* dev_fit,EvalInfo& eval, float* W, float* G) {

	cudaEvent_t startFitness, stopFitness;
	cudaEventCreate(&startFitness);
	cudaEventCreate(&stopFitness);

	cudaEventRecord(startFitness);
	fitness_knapsack << < POP_SIZE, MAX_THREADS_PER_BLOCK >> > (pop, dev_fit, length, W, G, MAX_WEIGHT, PENAL);
	cudaEventRecord(stopFitness);
	float milisecsFitness = 0;
	cudaEventElapsedTime(&milisecsFitness, startFitness, stopFitness);
	
	return evaluate_(POP_SIZE, dev_fit, eval);
}


ErrorInfo evaluate_bitwise(Data* pop, size_t POP_SIZE, int realLength,int length, float* dev_fit, EvalInfo& eval,float* W, float* G) {
	cudaEvent_t startFitness, stopFitness;
	cudaEventCreate(&startFitness);
	cudaEventCreate(&stopFitness);

	cudaEventRecord(startFitness);
	fitness_knapsack_b << < POP_SIZE, MAX_THREADS_PER_BLOCK >> > (pop, dev_fit, length,realLength, FirstBitMask, W, G, MAX_WEIGHT, PENAL);
	cudaEventRecord(stopFitness);
	float milisecsFitness = 0;
	cudaEventElapsedTime(&milisecsFitness, startFitness, stopFitness);

	return evaluate_(POP_SIZE, dev_fit, eval);

}


// Thamas Wang
// http://www.burtleburtle.net/bob/hash/integer.html
uint64_t hash64shift(uint64_t key)
{
	key = (~key) + (key << 21); // key = (key << 21) - key - 1;
	key = key ^ (key >>  24);
	key = (key + (key << 3)) + (key << 8); // key * 265
	key = key ^ (key >>  14);
	key = (key + (key << 2)) + (key << 4); // key * 21
	key = key ^ (key >>  28);
	key = key + (key << 31);
	return key;
}

/*__global__ void initPop_device(bool *pop, unsigned int length,unsigned long long seed) {
	unsigned int thIdx = blockIdx.x * blockDim.x + threadIdx.x;
	curandStatePhilox4_32_10_t rndState;
	curand_init(seed + thIdx, 0ull, 0ull, &rndState);
	for (unsigned int i = threadIdx.x; i < length; i = i + INIT_THREADS) {
		unsigned int pos = blockIdx.x * length + i;
		pop[pos] = (curand_uniform(&rndState) <= 0.5);
	}
}*/



/*__global__ void initPop_device32(bool *pop, unsigned int length, unsigned long long seed) {
	unsigned int thIdx = blockIdx.x * blockDim.x + threadIdx.x;
	curandStatePhilox4_32_10_t rndState;
	curand_init(seed + thIdx, 0ull, 0ull, &rndState);
	for (unsigned int i = threadIdx.x; i < length; ) {
		uint32_t rnd = curand(&rndState);
		for (uint32_t j = 0; j < 32 & i < length; j++, i = i + INIT_THREADS) {
			unsigned int pos = blockIdx.x * length + i;
			pop[pos] = (rnd & (1 << j)) != 0;
		}

	}
}*/







__global__ void WG_Fijos(float* W, float* G, int len) {
	unsigned int thIdx = blockIdx.x * blockDim.x + threadIdx.x;
	if (thIdx < len) {
		W[thIdx] = thIdx % 2 + 1;
		G[thIdx] = thIdx % 10;
	}

}


void inicializarWG(float** W, float** G, int len) {
	cudaMalloc(W, len * sizeof(float));
	cudaMalloc(G, len * sizeof(float));
	int blocks = ceil(len / MAX_THREADS_PER_BLOCK);
	WG_Fijos << <blocks, MAX_THREADS_PER_BLOCK >> > (*W, *G, len);


}

void generarAleatorioPacket(curandGenerator_t& generator, size_t bytes, void* buffer) {
	size_t N = (3 + bytes) / 4;
	unsigned int *ptr = reinterpret_cast<unsigned int*>(buffer);
	curandGenerate(generator, ptr, N);
}

void printInfo(int gen,const EvalInfo& eval ) {
	printf("gen %d: Inval: %d, AvgP: %.2f, MinV: %.0f, AvgV: %.1f, Max: %.0f\n", gen, eval.invalidos, eval.avgPenal, eval.minValido, eval.avgValido, eval.max);
}

ErrorInfo GA(size_t POP_SIZE,int len,int iters,bool dpx_cross,float crossProb,float mutProb,	unsigned long long seed) {
	/*cudaEvent_t start, stop;
	cudaEventCreate(&start);
	cudaEventCreate(&stop);*/
	double max_fitness;
	int gen_max_fitness = 0;
	if (dpx_cross) printf("DPX ");
	else printf("SPX ");

	printf("not bitwise POP_SIZE=%u length=%d seed=%u\n", POP_SIZE, len, seed);
	ErrorInfo status;
	bool *pop, *npop;
	float* fit;
	int* win; // indices de individuos ganadores en el tournment
	int* tourn;
	float  *probs;
	int *points;


	float *W;
	float *G;
	inicializarWG(&W, &G, len);

	EvalInfo eval;
	status.cuda = InitFit(&fit, POP_SIZE);
	status.cuda = InitWin(&win, POP_SIZE);
	status.cuda = InitTournRandom(&tourn, POP_SIZE);
	status = initProbs(&probs, &points, POP_SIZE);

	curandGenerator_t generator;
	status.curand = initGenerator(generator, seed);
	if (status.failed()) return status;


	//status = generatePOP(generator, POP_SIZE, len, &pop,&npop);
	// usa la curand device API para generar la poblacion sin prealocar numeros aleatorios para eso
	status = generatePOP_device(seed, POP_SIZE, len, &pop, &npop);
	//status = generatePOP_device(hash64shift(seed), POP_SIZE, len, &pop, &npop);

	// cambia el offset del generador para que no se sobreponga con el usado para la generacion de la poblacion
	curandSetGeneratorOffset(generator, POP_SIZE * len);

	if (status.failed()) {
		fprintf(stderr, "generatePOP failed!");
		return status;
	}

	
	status = evaluate(pop, POP_SIZE, len,fit,eval,W,G);
	max_fitness = eval.max;
	if (SALIDA) printInfo(0,eval);

	for (int gen = 1; gen <= iters; gen++) { // while not optimalSolutionFound
		// elegir POP_SIZE parejas para el torneo
		status = makeRandomNumbersTournement(generator, POP_SIZE, tourn);
		if (status.failed()) return status;

		// elegir POP_SIZE ganadores
		tournament<<< POP_SIZE / MAX_THREADS_PER_BLOCK, MAX_THREADS_PER_BLOCK>>> (fit, tourn, win);
		status.cuda = cudaGetLastError();
		if (status.failed()) return status;

		// seleccion
		if (dpx_cross) {
			makeRandomNumbersDpx(generator, POP_SIZE, len, probs, points);
			dpx << < POP_SIZE / 2, MAX_THREADS_PER_BLOCK >> >(pop, npop, win, probs, points, len, crossProb);
		}
		else {
			makeRandomNumbersSpx(generator, POP_SIZE, len, probs, points);
			spx << < POP_SIZE / 2, MAX_THREADS_PER_BLOCK >> >(pop, npop, win, probs, points, len, crossProb);
		}
		status.cuda = cudaGetLastError();
		if (status.failed()) return status;

		status.cuda = cudaDeviceSynchronize();
		if (status.failed()) return status;

		// elegir numeros aleatorios para mutacion 
		// se reusa la memoria que se uso para los numeros aleatorios de la seleccion
		status = makeRandomNumbersMutation(generator, POP_SIZE, len, probs, points);

		// mutacion
		mutation << < POP_SIZE / MAX_THREADS_PER_BLOCK, MAX_THREADS_PER_BLOCK >> >(npop, probs, points, len, mutProb);
		status.cuda = cudaGetLastError();
		if (status.failed()) return status;
		status.cuda = cudaDeviceSynchronize();

		bool* tmp;
		tmp = pop;
		pop = npop;
		npop = tmp;
		status = evaluate(pop, POP_SIZE, len, fit, eval, W, G);
		if (SALIDA && (gen % SALIDA_STEP) == 0) printInfo(gen, eval);
		if (eval.max > max_fitness) {
			gen_max_fitness = gen;
			max_fitness = eval.max;
		}
	}
	printf("Gen. max fitness: %d (%f)\n", gen_max_fitness, max_fitness);
	return status;
}

ErrorInfo GA_bitwise(size_t POP_SIZE, int len, int iters, bool dpx_cross, float crossProb, float mutProb,unsigned long long seed) {
	if (dpx_cross) printf("DPX "); 
	else printf("SPX ");
	printf("bitwise(%u) POP_SIZE=%u length=%d seed=%u\n",sizeof(Data) * 8, POP_SIZE, len, seed);
	ErrorInfo status;
	Data *pop, *npop;
	float* fit;
	int* win;  // indices de individuos ganadores en el tournment
	int* tourn;
	float  *probs;
	int *points;

	double max_fitness;
	int gen_max_fitness = 0;

	float *W;
	float *G;
	inicializarWG(&W, &G, len);


	EvalInfo eval;
	int realLength = (len + DataSize - 1) / DataSize;
	status.cuda = InitFit(&fit, POP_SIZE);
	status.cuda = InitWin(&win, POP_SIZE);
	status.cuda = InitTournRandom(&tourn, POP_SIZE);
	status = initProbs(&probs, &points, POP_SIZE);


	curandGenerator_t generator;
	status.curand = initGenerator(generator, seed);
	if (status.failed()) return status;


	//status = generatePOP(generator, POP_SIZE, len, &pop,&npop);
	// usa la curand device API para generar la poblacion sin prealocar numeros aleatorios para eso
	status = generatePOP_device_bitwise(seed, POP_SIZE, len, &pop, &npop);

	//generarAleatorioPacket(generator, realLength * DataSize / 8, (void*)pop);
	



	// cambia el offset del generador para que no se sobreponga con el usado para la generacion de la poblacion
	curandSetGeneratorOffset(generator, POP_SIZE * len);

	if (status.failed()) {
		fprintf(stderr, "generatePOP failed!");
		return status;
	}


	status = evaluate_bitwise(pop, POP_SIZE, realLength,len, fit, eval,W,G);
	max_fitness = eval.max;
	if (SALIDA)  printInfo(0, eval);

	for (int gen = 1; gen <= iters; gen++) { // while not optimalSolutionFound
											 // elegir POP_SIZE parejas para el torneo
		status = makeRandomNumbersTournement(generator, POP_SIZE, tourn);
		if (status.failed()) return status;

		// elegir POP_SIZE ganadores
		tournament << < POP_SIZE / MAX_THREADS_PER_BLOCK, MAX_THREADS_PER_BLOCK >> > (fit, tourn, win);
		status.cuda = cudaGetLastError();
		if (status.failed()) return status;

		// seleccion
		if (dpx_cross) {
			makeRandomNumbersDpx(generator, POP_SIZE, len, probs, points);
			dpx_b << < POP_SIZE / 2, MAX_THREADS_PER_BLOCK >> >(pop, npop, win, probs, points, realLength, crossProb);
		}
		else {
			makeRandomNumbersSpx(generator, POP_SIZE, len, probs, points);
			spx_b << < POP_SIZE / 2, MAX_THREADS_PER_BLOCK >> >(pop, npop, win, probs, points, realLength, crossProb);
		}
		status.cuda = cudaGetLastError();
		if (status.failed()) return status;

		status.cuda = cudaDeviceSynchronize();
		if (status.failed()) return status;

		// elegir numeros aleatorios para mutacion 
		// se reusa la memoria que se uso para los numeros aleatorios de la seleccion
		status = makeRandomNumbersMutation(generator, POP_SIZE, len, probs, points);

		// mutacion
		mutation_b << < POP_SIZE / MAX_THREADS_PER_BLOCK, MAX_THREADS_PER_BLOCK >> >(npop, probs, points, realLength, FirstBitMask, mutProb);
		status.cuda = cudaGetLastError();
		if (status.failed()) return status;
		status.cuda = cudaDeviceSynchronize();

		Data* tmp;
		tmp = pop;
		pop = npop;
		npop = tmp;
		status  = evaluate_bitwise(pop, POP_SIZE, realLength, len, fit, eval, W, G);
		if (SALIDA && (gen % SALIDA_STEP) == 0) printInfo(gen, eval);
		if (eval.max > max_fitness) {
			gen_max_fitness = gen;
			max_fitness = eval.max;
		}
	}
	printf("Gen. max fitness: %d (%f)\n", gen_max_fitness, max_fitness);
	return status;
}








int main()
{


	cudaError_t cudaStatus;
	ErrorInfo status;



	// Choose which GPU to run on, change this on a multi-GPU system.
	cudaStatus = cudaSetDevice(0);
	if (cudaStatus != cudaSuccess) {
		fprintf(stderr, "cudaSetDevice failed!  Do you have a CUDA-capable GPU installed?");
	}
	std::clock_t c_start = std::clock();

	// TODO: arreglar para POP_SIZE no multiplo de MAX_THREADS
	unsigned int POP_SIZE = 2048;
	int len = 10000;
	int iters = 10000;
	float pMutacion =0.4;
	float pCruce = 1;
	unsigned long long seed = 2825521;
	GA_bitwise(POP_SIZE, len, iters, true, pCruce,pMutacion,seed);
	std::clock_t c_end = std::clock();
	double time_elapsed_ms = 1000.0 * (c_end - c_start) / CLOCKS_PER_SEC;


	// cudaDeviceReset must be called before exiting in order for profiling and
	// tracing tools such as Nsight and Visual Profiler to show complete traces.
	cudaStatus = cudaDeviceReset();
	if (cudaStatus != cudaSuccess) {
		fprintf(stderr, "cudaDeviceReset failed!");
		return 1;
	}
	printf("Tiempo total: %.3fs\n", time_elapsed_ms / 1000.0);

	//std::cout << "Press any key to exit . . .";
	//std::cin.get();
	return 0;
}

