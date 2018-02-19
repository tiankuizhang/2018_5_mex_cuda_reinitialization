#include "mex.h"
#include "mexcudaReinitialization.hpp"
#include <cuda_runtime_api.h>

/**	
 * convert subindices to global indices 
 * for a 3d array stored in colum major
 */
__device__ inline 
int sub2ind(int const row_idx, int const col_idx, int const pge_idx, int const rows, int const cols, int const pages)
{
	return (pge_idx * rows * cols + col_idx * rows + row_idx);
}

__device__ inline 
double min_mod(double x, double y)
{
	return ( (x*y<0) ? 0 : (fabs(x)<fabs(y) ? x : y ));
}

__device__ inline
double min2(double x, double y)
{
	return ( (x<y) ? x : y );
}

__device__ inline
double max2(double x, double y)
{
	return ( (x<y) ? y : x );
}

__device__ inline
double sign(double x)
{
	return ( x>0 ? 1 : -1 );
}

__device__ inline
double discriminant(double p2, double v0, double v2)
{
	return ( pow(0.5*p2-v0-v2,2) - 4.*v0*v2 );
}

__device__ inline
double dist(double disc, double ds, double p2, double v0, double v2)
{
	return ( ds * (0.5 + (v0 - v2 - sign(v0-v2)*sqrt(disc)) / p2 ) );
}

__device__ inline
double dist_turn(double ds, double v0, double v2)
{
	return ( ds * v0 / (v0 - v2) );
}

__global__ 
void ExploreIdx(double * const dev_re_lsf, double const * const dev_lsf, int const number_of_elements_lsf,
	int const rows, int const cols, int const pages)
{
	int row_idx = blockIdx.x * blockDim.x + threadIdx.x;
	int col_idx = blockIdx.y * blockDim.y + threadIdx.y;
	int pge_idx = blockIdx.z * blockDim.z + threadIdx.z;

	//int idx = pge_idx * rows * cols + col_idx * rows + row_idx;
	int idx = sub2ind(row_idx, col_idx, pge_idx, rows, cols, pages);

	if(idx > number_of_elements_lsf)
		return;

	int right = sub2ind(row_idx, (col_idx < (cols-1)) ? col_idx+1 : col_idx+1-cols, pge_idx, rows, cols, pages );
	dev_re_lsf[idx] = dev_lsf[right];
} 

__global__
void boundary_correction(double * const dev_xpr, double * const dev_ypf, double * const dev_zpu, double * const dev_deltat,
	double const * const dev_lsf, int const number_of_elements_lsf, int const rows, int const cols, int const pages,
	double dx, double dy, double dz)
{	
	double epislon = 10e-10;

	int row_idx = blockIdx.x * blockDim.x + threadIdx.x;
	int col_idx = blockIdx.y * blockDim.y + threadIdx.y;
	int pge_idx = blockIdx.z * blockDim.z + threadIdx.z;

	int idx = sub2ind(row_idx, col_idx, pge_idx, rows, cols, pages);

	if(idx > number_of_elements_lsf)
		return;

	double f0 = dev_lsf[idx]; // grab the left node
	// fill in dev_xpr and make correction near boundary

	dev_deltat[idx] = min2(min2(dx,dy,),dz);

	dev_xpr[idx] = dx;
	int idx_right = sub2ind(row_idx, (col_idx < (cols-1)) ? col_idx+1 : col_idx+1-cols, pge_idx, rows, cols, pages );	
	double f2 = dev_lsf[idx_right]; // grab the right node

	double p2;

	if(f0*f2 < 0) // if there is a boundary to the right
	{
		int idx_left = sub2ind(row_idx, (col_idx > 0) ? col_idx-1 : col_idx-1+cols, pge_idx, rows, cols, pages);
		int idx_2right = sub2ind(row_idx, (col_idx < (cols-2) ? col_idx+2 : col_idx+2-cols), pge_idx, rows, cols, pages);

		double p2xl = dev_lsf[idx_left] - 2.0 * f0 + f2; // 2nd difference on the left node
		double p2xr = f0 - 2.0 * f2 + dev_lsf[idx_2right]; // 2nd difference on the right node
		p2 = min_mod(p2xl, p2xr);
		if(p2>epislon){
			dev_xpr[idx] = dist(discriminant(p2,f0,f2),dx,p2,f0,f2);
		} else{
			dev_xpr[idx] = dist_turn(dx,f0,f2);
		}
		dev_deltat[idx] = min2(dev_deltat[idx],dev_xpr[idx]);
		dev_deltat[idx_right] = min2(dev_deltat[idx_right],dx-dev_xpr[idx]);
	}

	// fill in dev_ypf
	dev_ypf[idx] = dy;
	int idx_front = sub2ind( (row_idx < (rows-1)) ? row_idx+1 : row_idx+1-rows, col_idx, pge_idx, rows, cols, pages);
	f2 = dev_lsf[idx_front]; // grab the front node value

	if(f0*f2 < 0) // if there is a boundary to the front
	{
		int idx_back = sub2ind( (row_idx > 0) ? row_idx-1 : row_idx-1+rows, col_idx, pge_idx, rows, cols, pages );
		int idx_2front = sub2ind( (row_idx < (rows-2)) ? row_idx+2 : row_idx+2-rows, col_idx, pge_idx, rows, cols, pages );

		double p2yb = dev_lsf[idx_back] - 2.0 * f0 + f2;
		double p2yf = f0 - 2.0 * f2 + dev_lsf[idx_2front];
		p2 = min_mod(p2yb, p2yf);
		if(p2>epislon){
			dev_ypf[idx] = dist(discriminant(p2,f0,f2),dy,p2,f0,f2);
		}else{
			dev_ypf[idx] = dist_turn(dy,f0,f2);
		}
		dev_deltat[idx] = min2(dev_deltat[idx],dev_ypf[idx]);
		dev_deltat[idx_front] = min2(dev_deltat[idx_front],dy-dev_ypf[idx]);
	}

	// fill in dev_zpu
	dev_zpu[idx] = dz;
	int idx_upper = sub2ind( row_idx, col_idx, (pge_idx < (pages-1)) ? pge_idx+1 : pge_idx+1-pages, rows, cols, pages );
	f2 = dev_lsf[idx_upper]; // grab the upper node value

	if(f0*f2 < 0) // if there is a boundary to the upper side
	{
		int idx_lower = sub2ind(row_idx, col_idx, (pge_idx > 0) ? pge_idx-1: pge_idx-1+pages, rows, cols, pages);
		int idx_2upper = sub2ind( row_idx, col_idx, (pge_idx < (pages-2)) ? pge_idx+2 : pge_idx+2-pages, rows, cols, pages );

		double p2zd = dev_lsf[idx_lower] - 2.0 * f0 + f2;
		double p2zu = f0 - 2.0 * f2 + dev_lsf[idx_2upper];
		p2 = min_mod(p2zd, p2zu);
		if(p2>epislon){
			dev_zpu[idx] = dist(discriminant(p2,f0,f2),dz,p2,f0,f2);
		}else{
			dev_ypf[idx] = dist_turn(dz,f0,f2);
		}
		dev_deltat[idx] = min2(dev_deltat[idx],dev_zpu[idx]);
		dev_deltat[idx_upper] = min2(dev_deltat[idx_upper],dx-dev_zpu[idx]);
	}

}

/*
 * reinitialization scheme
 * re_lsf : pointer to reinitialized level set function
 * lsf : pointer to input level set function
 */
void Reinitialization(double * re_lsf, double const * lsf, int const number_of_elements_lsf,
	int const rows, int const cols, int const pages, 
	double const dx, double const dy, double const dz)
{
	mexPrintf("hello cuda!\n");
	mexPrintf("number of elements : %d\n", number_of_elements_lsf);
	mexPrintf("dimension array:(%d,%d,%d)\n",rows,cols,pages);
	mexPrintf("grid spacing:(%f,%f,%f)\n",dx,dy,dz);

	// 
	int dimx = rows, dimy = 4, dimz = 1;
	dim3 const thread(dimx, dimy, dimz);
	dim3 const block((rows + thread.x - 1) / thread.x, (cols + thread.y - 1) / thread.y, (pages + thread.z - 1) / thread.z);

	mexPrintf("thread dimension (%d,%d,%d)\n", thread.x, thread.y, thread.z);
	mexPrintf("block dimension (%d,%d,%d)\n", block.x, block.y, block.z);

	// allocate memory for input lsf and out put level set function
	double * dev_lsf, * dev_re_lsf;
	cudaMalloc((void **)&dev_lsf, sizeof(double)*number_of_elements_lsf);
	cudaMalloc((void **)&dev_re_lsf, sizeof(double)*number_of_elements_lsf);

	// record information 
	//bool * dev_mask, * dev_mxr, * dev_mxl, * dev_myf, * dev_myb, * dev_mzu, * dev_mzd;

	cudaMemcpy((void *)dev_lsf, lsf, sizeof(double)*number_of_elements_lsf, cudaMemcpyHostToDevice);
	//cudaMemset((void *)dev_re_lsf, (int)0, sizeof(double)*number_of_elements_lsf);

	// allocate memory for boundary corrections
	double * dev_xpr, * dev_ypf, * dev_zpu, dev_deltat;
	cudaMalloc((void **)&dev_xpr, sizeof(double)*number_of_elements_lsf);
	cudaMalloc((void **)&dev_ypf, sizeof(double)*number_of_elements_lsf);
	cudaMalloc((void **)&dev_zpu, sizeof(double)*number_of_elements_lsf);
	cudaMalloc((void **)&dev_deltat, sizeof(double)*number_of_elements_lsf);

	boundary_correction<<<block, thread>>>(dev_xpr, dev_ypf, dev_zpu, dev_deltat, dev_lsf, number_of_elements_lsf, rows, cols, pages, dx, dy, dz);

	ExploreIdx<<<block, thread>>>(dev_re_lsf, dev_lsf, number_of_elements_lsf, rows, cols, pages);

	// copy results back 
	cudaMemcpy(re_lsf, (void *)dev_re_lsf, sizeof(double)*number_of_elements_lsf, cudaMemcpyDeviceToHost);

	cudaFree(dev_lsf);
	cudaFree(dev_re_lsf);
	cudaFree(dev_xpr);
	cudaFree(dev_ypf);
	cudaFree(dev_zpu);
	cudaFree(dev_deltat);

}












