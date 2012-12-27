/*
 * =====================================================================================
 *
 *       Filename:  decode.cu
 *
 *    Description:  
 *
 *        Version:  1.0
 *        Created:  12/05/2012 10:50:55 PM
 *       Revision:  none
 *       Compiler:  nvcc
 *
 *         Author:  Shuai YUAN (yszheda AT gmail.com), 
 *        Company:  
 *
 * =====================================================================================
 */

#include <stdio.h>
#include <cuda.h>
#include <stdlib.h>
#include <stdint.h>
#include "matrix.h"

#define DEBUG

void show_squre_matrix(uint8_t *matrix, int size)
{
	int i;
	int j;
	for(i=0; i<size; i++)
	{
		for(j=0; j<size; j++)
		{
			printf("%d ", matrix[i*size+j]);
		}
		printf("\n");
	}
}

void copy_matrix(uint8_t *src, uint8_t *des, int srcRowIndex, int desRowIndex, int rowSize)
{
	int i;
	for(i=0; i<rowSize; i++)
	{
		des[desRowIndex*rowSize+i] = src[srcRowIndex*rowSize+i];
	}
}

extern "C"
void decode(uint8_t *dataBuf, uint8_t *codeBuf, uint8_t *encodingMatrix, int nativeBlockNum, int parityBlockNum, int chunkSize)
{
	int dataSize = nativeBlockNum*chunkSize*sizeof(uint8_t);
	int codeSize = nativeBlockNum*chunkSize*sizeof(uint8_t);
	uint8_t *dataBuf_d;		//device
	uint8_t *codeBuf_d;		//device
	cudaMalloc( (void **)&dataBuf_d, dataSize );
//	cudaMemset(dataBuf_d, 0, dataSize);
	cudaMalloc( (void **)&codeBuf_d, codeSize );
//	cudaMemset(codeBuf_d, 0, codeSize);
	cudaMemcpy(codeBuf_d, codeBuf, codeSize, cudaMemcpyHostToDevice);

	int matrixSize = nativeBlockNum * nativeBlockNum;
	uint8_t *encodingMatrix_d;	//device
	uint8_t *decodingMatrix_d;	//device
	cudaMalloc( (void **)&encodingMatrix_d, matrixSize );
	cudaMalloc( (void **)&decodingMatrix_d, matrixSize );
	cudaMemcpy(encodingMatrix_d, encodingMatrix, matrixSize, cudaMemcpyHostToDevice);

	float time;
	// compute the execution time
	cudaEvent_t start, stop;
	// create event
	cudaEventCreate(&start);
	cudaEventCreate(&stop);
	// record event
	cudaEventRecord(start);
    invert_matrix(encodingMatrix_d, decodingMatrix_d, nativeBlockNum);
	// record event and synchronize
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
	// get event elapsed time
	cudaEventElapsedTime(&time, start, stop);
	printf("Generating decoding matrix completed: %fms\n", time);

#ifdef DEBUG
	uint8_t *decodingMatrix;	//host
	decodingMatrix = (uint8_t*) malloc( matrixSize );
	cudaMemcpy(decodingMatrix, decodingMatrix_d, matrixSize, cudaMemcpyDeviceToHost);
	show_squre_matrix(decodingMatrix, nativeBlockNum);
	free(decodingMatrix);
#endif

	// record event
	cudaEventRecord(start);
//	int gridDimX = (int)(ceil((float)chunkSize/TILE_WIDTH));
//	int gridDimY = (int)(ceil((float)parityBlockNum/TILE_WIDTH));
//	dim3 grid(gridDimX, gridDimY);
//	dim3 block(TILE_WIDTH, TILE_WIDTH);

//	int gridDimX = (int)( ceil((float)chunkSize / TILE_WIDTH_COL) );
	int gridDimX = min( (int)( ceil((float)chunkSize / TILE_WIDTH_COL) ), SINGLE_GRID_SIZE );
	int gridDimY = (int)( ceil((float)nativeBlockNum / TILE_WIDTH_ROW) );
	dim3 grid(gridDimX, gridDimY);
//	dim3 block(TILE_WIDTH_ROW, TILE_WIDTH_COL);
	dim3 block(TILE_WIDTH_COL, TILE_WIDTH_ROW);
	decode_chunk<<<grid, block>>>(dataBuf_d, decodingMatrix_d, codeBuf_d, nativeBlockNum, parityBlockNum, chunkSize);
	// record event and synchronize
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
	// get event elapsed time
	cudaEventElapsedTime(&time, start, stop);
	printf("Decoding file completed: %fms\n", time);

	cudaMemcpy(dataBuf, dataBuf_d, dataSize, cudaMemcpyDeviceToHost);

	cudaFree(decodingMatrix_d);
	cudaFree(dataBuf_d);
	cudaFree(codeBuf_d);
}

extern "C"
void decode_file(char *confFile, int nativeBlockNum, int parityBlockNum)
{
	int chunkSize = 1;
	int totalSize;

	uint8_t *dataBuf;		//host
	uint8_t *codeBuf;		//host

	int dataSize;
	int codeSize;

	FILE *fp_in;
	FILE *fp_out;

	int totalMatrixSize;
	int matrixSize;
	uint8_t *totalEncodingMatrix;	//host
	uint8_t *encodingMatrix;	//host
	if( ( fp_in = fopen(".METADATA","rb") ) == NULL )
	{
		printf("Can not open source file!\n");
		exit(0);
	}
	fscanf(fp_in, "%d", &totalSize);
	fscanf(fp_in, "%d %d", &parityBlockNum, &nativeBlockNum);
	chunkSize = (int) (ceil( (float)totalSize / nativeBlockNum )); 
#ifdef DEBUG
printf("chunk size: %d\n", chunkSize);
#endif
	totalMatrixSize = nativeBlockNum * ( nativeBlockNum + parityBlockNum );
	totalEncodingMatrix = (uint8_t*) malloc( totalMatrixSize );
	matrixSize = nativeBlockNum * nativeBlockNum;
	encodingMatrix = (uint8_t*) malloc( matrixSize );
	for(int i =0; i<nativeBlockNum*(nativeBlockNum+parityBlockNum); i++)
	{
		fscanf(fp_in, "%d", totalEncodingMatrix+i);
	}

	dataSize = nativeBlockNum*chunkSize*sizeof(uint8_t);
	codeSize = nativeBlockNum*chunkSize*sizeof(uint8_t);
	dataBuf = (uint8_t*) malloc( dataSize );
	memset(dataBuf, 0, dataSize);
	codeBuf = (uint8_t*) malloc( codeSize);
	memset(codeBuf, 0, codeSize);

	if(confFile != NULL)
	{
		FILE *fp_conf;
		char input_file_name[100];
		int index;
		fp_conf = fopen(confFile, "r");

		for(int i=0; i<nativeBlockNum; i++)
		{
			fscanf(fp_conf, "%s", input_file_name);
			index = atoi(input_file_name+1);

			copy_matrix(totalEncodingMatrix, encodingMatrix, index, i, nativeBlockNum);

			fp_in = fopen(input_file_name, "rb");
			fseek(fp_in, 0L, SEEK_SET);
			// this part can be process in parallel with computing inversed matrix
			fread(codeBuf+i*chunkSize, sizeof(uint8_t), chunkSize, fp_in);
			fclose(fp_in);
		}
		fclose(fp_conf);
	}
	else
	{
		for(int i=0; i<nativeBlockNum; i++)
		{
			char input_file_name[100];
			int index;
			printf("Please enter the file name of fragment:\n");
			scanf("%s", input_file_name);
			index = atoi(input_file_name+1);
			printf("#%dth fragment\n", index);

			copy_matrix(totalEncodingMatrix, encodingMatrix, index, i, nativeBlockNum);

			fp_in = fopen(input_file_name, "rb");
			fseek(fp_in, 0L, SEEK_SET);
			// this part can be process in parallel with computing inversed matrix
			fread(codeBuf+i*chunkSize, sizeof(uint8_t), chunkSize, fp_in);
			fclose(fp_in);

		}
	}
/*
	for(int i=0; i<nativeBlockNum; i++)
	{
		char input_file_name[20];
		int index;
		printf("Please enter the file name of fragment:\n");
		scanf("%s", input_file_name);
		index = atoi(input_file_name+1);
		printf("#%dth fragment\n", index);

		copy_matrix(totalEncodingMatrix, encodingMatrix, index, i, nativeBlockNum);

		fp_in = fopen(input_file_name, "rb");
		fseek(fp_in, 0L, SEEK_SET);
		// this part can be process in parallel with computing inversed matrix
		fread(codeBuf+i*chunkSize, sizeof(uint8_t), chunkSize, fp_in);
		fclose(fp_in);

	}
*/
	
	decode(dataBuf, codeBuf, encodingMatrix, nativeBlockNum, parityBlockNum, chunkSize);

	char output_file_name[100];
	printf("Enter the name of the decoded file:\n");
	scanf("%s", output_file_name);
	fp_out = fopen(output_file_name, "wb");
	fwrite(dataBuf, sizeof(uint8_t), totalSize, fp_out);
	fclose(fp_out);

	free(dataBuf);
	free(codeBuf);

}