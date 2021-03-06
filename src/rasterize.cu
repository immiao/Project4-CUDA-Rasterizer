/**
 * @file      rasterize.cu
 * @brief     CUDA-accelerated rasterization pipeline.
 * @authors   Skeleton code: Yining Karl Li, Kai Ninomiya, Shuai Shao (Shrek)
 * @date      2012-2016
 * @copyright University of Pennsylvania & STUDENT
 */
#include <thrust/remove.h>
#include <thrust/device_vector.h>
#include <thrust/count.h>

#include <cmath>
#include <cstdio>
#include <cuda.h>
#include <cuda_runtime.h>
#include <thrust/random.h>
#include <util/checkCUDAError.h>
#include <util/tiny_gltf_loader.h>
#include "rasterizeTools.h"
#include "rasterize.h"
#include <glm/gtc/quaternion.hpp>
#include <glm/gtc/matrix_transform.hpp>
#include <algorithm>



//namespace 

	typedef unsigned short VertexIndex;
	typedef glm::vec3 VertexAttributePosition;
	typedef glm::vec3 VertexAttributeNormal;
	typedef glm::vec2 VertexAttributeTexcoord;
	typedef unsigned char TextureData;

	typedef unsigned char BufferByte;

	enum PrimitiveType{
		Point = 1,
		Line = 2,
		Triangle = 3
	};

	struct VertexOut {
		glm::vec4 pos;

		// TODO: add new attributes to your VertexOut
		// The attributes listed below might be useful, 
		// but always feel free to modify on your own

		 glm::vec3 eyePos;	// eye space position used for shading
		 glm::vec3 eyeNor;	// eye space normal used for shading, cuz normal will go wrong after perspective transformation
		 glm::vec3 col;

		 glm::vec2 texcoord0;
		 TextureData* dev_diffuseTex;
		 int diffuseTexHeight;
		 int diffuseTexWidth;
		 int diffuseTexComponent;
		// ...
		 VertexOut()
		 {
			 dev_diffuseTex = NULL;
		 }
	};

	struct Primitive {
		PrimitiveType primitiveType;	// C++ 11 init
		VertexOut v[3];
		Primitive()
		{
			primitiveType = Triangle;
		}
	};

	struct Fragment {
		glm::vec3 color;

		// TODO: add new attributes to your Fragment
		// The attributes listed below might be useful, 
		// but always feel free to modify on your own

		glm::vec3 eyePos;	// eye space position used for shading
		glm::vec3 eyeNor;
		float z;
	    VertexAttributeTexcoord texcoord0;
	    TextureData* dev_diffuseTex;
		int diffuseTexWidth;
		int diffuseTexHeight;
		int diffuseTexComponent;
		bool hasColor;
		Fragment()
		{
			dev_diffuseTex = NULL;
			hasColor = false;
		}
		// ...
	};

	struct PrimitiveDevBufPointers {
		int primitiveMode;	//from tinygltfloader macro
		PrimitiveType primitiveType;
		int numPrimitives;
		int numIndices;
		int numVertices;

		// Vertex In, const after loaded
		VertexIndex* dev_indices;
		VertexAttributePosition* dev_position;
		VertexAttributeNormal* dev_normal;
		VertexAttributeTexcoord* dev_texcoord0;

		// Materials, add more attributes when needed
		TextureData* dev_diffuseTex;
		int diffuseTexWidth;
		int diffuseTexHeight;
		int diffuseTexComponent;
		// TextureData* dev_specularTex;
		// TextureData* dev_normalTex;
		// ...

		// Vertex Out, vertex used for rasterization, this is changing every frame
		VertexOut* dev_verticesOut;
		PrimitiveDevBufPointers(){}
		PrimitiveDevBufPointers(int tPrimitiveMode,
								PrimitiveType tPrimitiveType,
								int tNumPrimitives,
								int tNumIndices,
								int tNumVertices,
								VertexIndex *tDev_indices,
								VertexAttributePosition *tDev_position,
								VertexAttributeNormal *tDev_normal,
								VertexAttributeTexcoord *tDev_texcoord0,
								TextureData *tDev_diffuseTex,
								int tDiffuseTexWidth,
								int tDiffuseTexHeight,
								int tDiffuseTexComponent,
								VertexOut *tDev_verticesOut)
		{
			primitiveMode = tPrimitiveMode;
			primitiveType = tPrimitiveType;
			numPrimitives = tNumPrimitives;
			numIndices = tNumIndices;
			numVertices = tNumVertices;

			dev_indices = tDev_indices;
			dev_position = tDev_position;
			dev_normal = tDev_normal;
			dev_texcoord0 = tDev_texcoord0;

			dev_diffuseTex = tDev_diffuseTex;
			diffuseTexWidth = tDiffuseTexWidth;
			diffuseTexHeight = tDiffuseTexHeight;
			diffuseTexComponent = tDiffuseTexComponent;

			dev_verticesOut = tDev_verticesOut;
		}
		// TODO: add more attributes when needed
	};




static std::map<std::string, std::vector<PrimitiveDevBufPointers>> mesh2PrimitivesMap;


static int width = 0;
static int height = 0;

static int totalNumPrimitives = 0;
static Primitive *dev_primitives = NULL;
static Fragment *dev_fragmentBuffer = NULL;
static glm::vec3 *dev_framebuffer = NULL;

bool *dev_flag = NULL;
int *dev_mutex = NULL;

static int * dev_depth = NULL;	// you might need this buffer when doing depth test

/**
 * Kernel that writes the image to the OpenGL PBO directly.
 */
__global__ 
void sendImageToPBO(uchar4 *pbo, int w, int h, glm::vec3 *image) {
    int x = (blockIdx.x * blockDim.x) + threadIdx.x;
    int y = (blockIdx.y * blockDim.y) + threadIdx.y;
    int index = x + (y * w);

    if (x < w && y < h) {
        glm::vec3 color;
        color.x = glm::clamp(image[index].x, 0.0f, 1.0f) * 255.0;
        color.y = glm::clamp(image[index].y, 0.0f, 1.0f) * 255.0;
        color.z = glm::clamp(image[index].z, 0.0f, 1.0f) * 255.0;
        // Each thread writes one pixel location in the texture (textel)
        pbo[index].w = 0;
        pbo[index].x = color.x;
        pbo[index].y = color.y;
        pbo[index].z = color.z;
    }
}

/** 
* Writes fragment colors to the framebuffer
*/
__global__
void render(int w, int h, Fragment *fragmentBuffer, glm::vec3 *framebuffer) {
    int x = (blockIdx.x * blockDim.x) + threadIdx.x;
    int y = (blockIdx.y * blockDim.y) + threadIdx.y;
    int index = x + (y * w);
	glm::vec3 lightPos(5.0f, 5.0f, 5.0f);
	Fragment cacheFragment = fragmentBuffer[index];
	if (x < w && y < h && cacheFragment.hasColor) {
		float diffuseTerm = 0.4 * glm::clamp(glm::dot(cacheFragment.eyeNor, glm::normalize(lightPos - cacheFragment.eyePos)), 0.0f, 1.0f);
		float ambientTerm = 0.6f;
		glm::vec3 L = glm::normalize(lightPos - cacheFragment.eyePos);
		glm::vec3 N = cacheFragment.eyeNor;
		glm::vec3 V = glm::normalize(-cacheFragment.eyePos);
		glm::vec3 H = glm::normalize(V + L);
		//printf("norm:%f %f %f\nH:%f %f %f\n\n", L[0], L[1], L[2], 
		//	cacheFragment.eyePos[0], cacheFragment.eyePos[1], cacheFragment.eyePos[2]);
		glm::vec3 textureColor;// = glm::vec3(1.0f, 1.0f, 1.0f);
		if (cacheFragment.dev_diffuseTex != NULL)
		{
			//if (!(cacheFragment.diffuseTexWidth>0 && cacheFragment.diffuseTexHeight>0 & cacheFragment.diffuseTexComponent>0))
			//	printf("com:%d %d %d\n", cacheFragment.diffuseTexWidth, cacheFragment.diffuseTexHeight, cacheFragment.diffuseTexComponent);
			//textureColor = cacheFragment.color * (diffuseTerm + ambientTerm);//
			textureColor = getTextureColor(cacheFragment.dev_diffuseTex, cacheFragment.texcoord0, cacheFragment.diffuseTexWidth, cacheFragment.diffuseTexHeight, cacheFragment.diffuseTexComponent);
			//textureColor = getBilinearTextureColor(cacheFragment.dev_diffuseTex, cacheFragment.texcoord0, cacheFragment.diffuseTexWidth, cacheFragment.diffuseTexHeight, cacheFragment.diffuseTexComponent);
			//textureColor = glm::vec3(cacheFragment.texcoord0, 0.0f);
			//printf("coord:%f %f\ncolor:%f %f %f\n\n", cacheFragment.texcoord0[0], cacheFragment.texcoord0[1], textureColor[0], textureColor[1], textureColor[2]);
			
		}
		else
		{
			textureColor = cacheFragment.color * (diffuseTerm + ambientTerm);
			//printf("%f %f %f\n", textureColor[0], textureColor[1], textureColor[2]);
		}
		//printf("%f %f\n", fragmentBuffer[index].texcoord0[0], fragmentBuffer[index].texcoord0[1]);
        //framebuffer[index] = fragmentBuffer[index].color * (diffuseTerm + ambientTerm);// * textureColor;
		//framebuffer[index] = fragmentBuffer[index].color;// * (diffuseTerm + ambientTerm);
		//framebuffer[index] = textureColor * (diffuseTerm + ambientTerm);
		framebuffer[index] = textureColor * (diffuseTerm + ambientTerm) + pow(max(0.0f, glm::dot(N, H)), 200.0f);
		//printf("%f\n", pow(max(0.0f, glm::dot(N, H)), 200.0f));
		// TODO: add your fragment shader code here

    }
	else
		framebuffer[index] = glm::vec3(0.0f, 0.0f, 0.0f);
}

/**
 * Called once at the beginning of the program to allocate memory.
 */
void rasterizeInit(int w, int h) {
    width = w;
    height = h;
	cudaFree(dev_fragmentBuffer);
	cudaMalloc(&dev_fragmentBuffer, width * height * sizeof(Fragment));
	cudaMemset(dev_fragmentBuffer, 0, width * height * sizeof(Fragment));
    cudaFree(dev_framebuffer);
    cudaMalloc(&dev_framebuffer,   width * height * sizeof(glm::vec3));
    cudaMemset(dev_framebuffer, 0, width * height * sizeof(glm::vec3));
    
	cudaFree(dev_depth);
	cudaMalloc(&dev_depth, width * height * sizeof(int));

	cudaMalloc(&dev_mutex, width * height * sizeof(int));
	checkCUDAError("rasterizeInit");
}

__global__
void initDepth(int w, int h, int * depth, Fragment *f)
{
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	if (x < w && y < h)
	{
		int index = x + (y * w);
		depth[index] = INT_MAX;
		f[index].z = 2.0f;
		f[index].hasColor = false;
		//f[index].texcoord0 = glm::vec2(-1.0f, -1.0f);
	}
}
#define SCALE 100000;

/**
* kern function with support for stride to sometimes replace cudaMemcpy
* One thread is responsible for copying one component
*/
__global__ 
void _deviceBufferCopy(int N, BufferByte* dev_dst, const BufferByte* dev_src, int n, int byteStride, int byteOffset, int componentTypeByteSize) {
	
	// Attribute (vec3 position)
	// component (3 * float)
	// byte (4 * byte)

	// id of component
	int i = (blockIdx.x * blockDim.x) + threadIdx.x;

	if (i < N) {
		int count = i / n;
		int offset = i - count * n;	// which component of the attribute

		for (int j = 0; j < componentTypeByteSize; j++) {
			
			dev_dst[count * componentTypeByteSize * n 
				+ offset * componentTypeByteSize 
				+ j]

				= 

			dev_src[byteOffset 
				+ count * (byteStride == 0 ? componentTypeByteSize * n : byteStride) 
				+ offset * componentTypeByteSize 
				+ j];
		}
	}
	

}

__global__
void _nodeMatrixTransform(
	int numVertices,
	VertexAttributePosition* position,
	VertexAttributeNormal* normal,
	glm::mat4 MV, glm::mat3 MV_normal) {

	// vertex id
	int vid = (blockIdx.x * blockDim.x) + threadIdx.x;
	if (vid < numVertices) {
		position[vid] = glm::vec3(MV * glm::vec4(position[vid], 1.0f));
		normal[vid] = glm::normalize(MV_normal * normal[vid]);
	}
}

glm::mat4 getMatrixFromNodeMatrixVector(const tinygltf::Node & n) {
	
	glm::mat4 curMatrix(1.0);

	const std::vector<double> &m = n.matrix;
	if (m.size() > 0) {
		// matrix, copy it

		for (int i = 0; i < 4; i++) {
			for (int j = 0; j < 4; j++) {
				curMatrix[i][j] = (float)m.at(4 * i + j);
			}
		}
	} else {
		// no matrix, use rotation, scale, translation

		if (n.translation.size() > 0) {
			curMatrix[3][0] = n.translation[0];
			curMatrix[3][1] = n.translation[1];
			curMatrix[3][2] = n.translation[2];
		}

		if (n.rotation.size() > 0) {
			glm::mat4 R;
			glm::quat q;
			q[0] = n.rotation[0];
			q[1] = n.rotation[1];
			q[2] = n.rotation[2];

			R = glm::mat4_cast(q);
			curMatrix = curMatrix * R;
		}

		if (n.scale.size() > 0) {
			curMatrix = curMatrix * glm::scale(glm::vec3(n.scale[0], n.scale[1], n.scale[2]));
		}
	}

	return curMatrix;
}

void traverseNode (
	std::map<std::string, glm::mat4> & n2m,
	const tinygltf::Scene & scene,
	const std::string & nodeString,
	const glm::mat4 & parentMatrix
	) 
{
	const tinygltf::Node & n = scene.nodes.at(nodeString);
	glm::mat4 M = parentMatrix * getMatrixFromNodeMatrixVector(n);
	n2m.insert(std::pair<std::string, glm::mat4>(nodeString, M));

	auto it = n.children.begin();
	auto itEnd = n.children.end();

	for (; it != itEnd; ++it) {
		traverseNode(n2m, scene, *it, M);
	}
}

void rasterizeSetBuffers(const tinygltf::Scene & scene) {

	totalNumPrimitives = 0;

	std::map<std::string, BufferByte*> bufferViewDevPointers;

	// 1. copy all `bufferViews` to device memory
	{
		std::map<std::string, tinygltf::BufferView>::const_iterator it(
			scene.bufferViews.begin());
		std::map<std::string, tinygltf::BufferView>::const_iterator itEnd(
			scene.bufferViews.end());

		for (; it != itEnd; it++) {
			const std::string key = it->first;
			const tinygltf::BufferView &bufferView = it->second;
			if (bufferView.target == 0) {
				continue; // Unsupported bufferView.
			}

			const tinygltf::Buffer &buffer = scene.buffers.at(bufferView.buffer);

			BufferByte* dev_bufferView;
			cudaMalloc(&dev_bufferView, bufferView.byteLength);
			cudaMemcpy(dev_bufferView, &buffer.data.front() + bufferView.byteOffset, bufferView.byteLength, cudaMemcpyHostToDevice);

			checkCUDAError("Set BufferView Device Mem");

			bufferViewDevPointers.insert(std::make_pair(key, dev_bufferView));

		}
	}



	// 2. for each mesh: 
	//		for each primitive: 
	//			build device buffer of indices, materail, and each attributes
	//			and store these pointers in a map
	{

		std::map<std::string, glm::mat4> nodeString2Matrix;
		auto rootNodeNamesList = scene.scenes.at(scene.defaultScene);

		{
			auto it = rootNodeNamesList.begin();
			auto itEnd = rootNodeNamesList.end();
			for (; it != itEnd; ++it) {
				traverseNode(nodeString2Matrix, scene, *it, glm::mat4(1.0f));
			}
		}


		// parse through node to access mesh

		auto itNode = nodeString2Matrix.begin();
		auto itEndNode = nodeString2Matrix.end();
		for (; itNode != itEndNode; ++itNode) {

			const tinygltf::Node & N = scene.nodes.at(itNode->first);
			const glm::mat4 & matrix = itNode->second;
			const glm::mat3 & matrixNormal = glm::transpose(glm::inverse(glm::mat3(matrix)));

			auto itMeshName = N.meshes.begin();
			auto itEndMeshName = N.meshes.end();

			for (; itMeshName != itEndMeshName; ++itMeshName) {

				const tinygltf::Mesh & mesh = scene.meshes.at(*itMeshName);

				auto res = mesh2PrimitivesMap.insert(std::pair<std::string, std::vector<PrimitiveDevBufPointers>>(mesh.name, std::vector<PrimitiveDevBufPointers>()));
				std::vector<PrimitiveDevBufPointers> & primitiveVector = (res.first)->second;

				// for each primitive
				for (size_t i = 0; i < mesh.primitives.size(); i++) {
					const tinygltf::Primitive &primitive = mesh.primitives[i];

					if (primitive.indices.empty())
						return;

					// TODO: add new attributes for your PrimitiveDevBufPointers when you add new attributes
					VertexIndex* dev_indices = NULL;
					VertexAttributePosition* dev_position = NULL;
					VertexAttributeNormal* dev_normal = NULL;
					VertexAttributeTexcoord* dev_texcoord0 = NULL;

					// ----------Indices-------------

					const tinygltf::Accessor &indexAccessor = scene.accessors.at(primitive.indices);
					const tinygltf::BufferView &bufferView = scene.bufferViews.at(indexAccessor.bufferView);
					BufferByte* dev_bufferView = bufferViewDevPointers.at(indexAccessor.bufferView);

					// assume type is SCALAR for indices
					int n = 1;
					int numIndices = indexAccessor.count;
					int componentTypeByteSize = sizeof(VertexIndex);
					int byteLength = numIndices * n * componentTypeByteSize;

					dim3 numThreadsPerBlock(128);
					dim3 numBlocks((numIndices + numThreadsPerBlock.x - 1) / numThreadsPerBlock.x);
					cudaMalloc(&dev_indices, byteLength);
					_deviceBufferCopy << <numBlocks, numThreadsPerBlock >> > (
						numIndices,
						(BufferByte*)dev_indices,
						dev_bufferView,
						n,
						indexAccessor.byteStride,
						indexAccessor.byteOffset,
						componentTypeByteSize);


					checkCUDAError("Set Index Buffer");


					// ---------Primitive Info-------

					// Warning: LINE_STRIP is not supported in tinygltfloader
					int numPrimitives;
					PrimitiveType primitiveType;
					switch (primitive.mode) {
					case TINYGLTF_MODE_TRIANGLES:
						primitiveType = PrimitiveType::Triangle;
						numPrimitives = numIndices / 3;
						break;
					case TINYGLTF_MODE_TRIANGLE_STRIP:
						primitiveType = PrimitiveType::Triangle;
						numPrimitives = numIndices - 2;
						break;
					case TINYGLTF_MODE_TRIANGLE_FAN:
						primitiveType = PrimitiveType::Triangle;
						numPrimitives = numIndices - 2;
						break;
					case TINYGLTF_MODE_LINE:
						primitiveType = PrimitiveType::Line;
						numPrimitives = numIndices / 2;
						break;
					case TINYGLTF_MODE_LINE_LOOP:
						primitiveType = PrimitiveType::Line;
						numPrimitives = numIndices + 1;
						break;
					case TINYGLTF_MODE_POINTS:
						primitiveType = PrimitiveType::Point;
						numPrimitives = numIndices;
						break;
					default:
						// output error
						break;
					};


					// ----------Attributes-------------

					auto it(primitive.attributes.begin());
					auto itEnd(primitive.attributes.end());

					int numVertices = 0;
					// for each attribute
					for (; it != itEnd; it++) {
						const tinygltf::Accessor &accessor = scene.accessors.at(it->second);
						const tinygltf::BufferView &bufferView = scene.bufferViews.at(accessor.bufferView);

						int n = 1;
						if (accessor.type == TINYGLTF_TYPE_SCALAR) {
							n = 1;
						}
						else if (accessor.type == TINYGLTF_TYPE_VEC2) {
							n = 2;
						}
						else if (accessor.type == TINYGLTF_TYPE_VEC3) {
							n = 3;
						}
						else if (accessor.type == TINYGLTF_TYPE_VEC4) {
							n = 4;
						}

						BufferByte * dev_bufferView = bufferViewDevPointers.at(accessor.bufferView);
						BufferByte ** dev_attribute = NULL;

						numVertices = accessor.count;
						int componentTypeByteSize;

						// Note: since the type of our attribute array (dev_position) is static (float32)
						// We assume the glTF model attribute type are 5126(FLOAT) here

						if (it->first.compare("POSITION") == 0) {
							componentTypeByteSize = sizeof(VertexAttributePosition) / n;
							dev_attribute = (BufferByte**)&dev_position;
						}
						else if (it->first.compare("NORMAL") == 0) {
							componentTypeByteSize = sizeof(VertexAttributeNormal) / n;
							dev_attribute = (BufferByte**)&dev_normal;
						}
						else if (it->first.compare("TEXCOORD_0") == 0) {
							componentTypeByteSize = sizeof(VertexAttributeTexcoord) / n;
							dev_attribute = (BufferByte**)&dev_texcoord0;
						}

						std::cout << accessor.bufferView << "  -  " << it->second << "  -  " << it->first << '\n';

						dim3 numThreadsPerBlock(128);
						dim3 numBlocks((n * numVertices + numThreadsPerBlock.x - 1) / numThreadsPerBlock.x);
						int byteLength = numVertices * n * componentTypeByteSize;
						cudaMalloc(dev_attribute, byteLength);

						_deviceBufferCopy << <numBlocks, numThreadsPerBlock >> > (
							n * numVertices,
							*dev_attribute,
							dev_bufferView,
							n,
							accessor.byteStride,
							accessor.byteOffset,
							componentTypeByteSize);

						std::string msg = "Set Attribute Buffer: " + it->first;
						checkCUDAError(msg.c_str());
					}

					// malloc for VertexOut
					VertexOut* dev_vertexOut;
					cudaMalloc(&dev_vertexOut, numVertices * sizeof(VertexOut));
					checkCUDAError("Malloc VertexOut Buffer");

					// ----------Materials-------------

					// You can only worry about this part once you started to 
					// implement textures for your rasterizer
					TextureData* dev_diffuseTex = NULL;
					int diffuseTexWidth = 0;
					int diffuseTexHeight = 0;
					int diffuseTexComponent = 0;

					if (!primitive.material.empty()) {
						const tinygltf::Material &mat = scene.materials.at(primitive.material);
						printf("material.name = %s\n", mat.name.c_str());

						if (mat.values.find("diffuse") != mat.values.end()) {
							std::string diffuseTexName = mat.values.at("diffuse").string_value;
							if (scene.textures.find(diffuseTexName) != scene.textures.end()) {
								const tinygltf::Texture &tex = scene.textures.at(diffuseTexName);
								if (scene.images.find(tex.source) != scene.images.end()) {
									const tinygltf::Image &image = scene.images.at(tex.source);

									size_t s = image.image.size() * sizeof(TextureData);
									cudaMalloc(&dev_diffuseTex, s);
									cudaMemcpy(dev_diffuseTex, &image.image.at(0), s, cudaMemcpyHostToDevice);
									
									diffuseTexWidth = image.width;
									diffuseTexHeight = image.height;
									diffuseTexComponent = image.component;
									//printf("HH:%d\n", diffuseTexComponent);
									checkCUDAError("Set Texture Image data");
								}
							}
						}

						// TODO: write your code for other materails
						// You may have to take a look at tinygltfloader
						// You can also use the above code loading diffuse material as a start point 
					}


					// ---------Node hierarchy transform--------
					cudaDeviceSynchronize();
					
					dim3 numBlocksNodeTransform((numVertices + numThreadsPerBlock.x - 1) / numThreadsPerBlock.x);
					_nodeMatrixTransform << <numBlocksNodeTransform, numThreadsPerBlock >> > (
						numVertices,
						dev_position,
						dev_normal,
						matrix,
						matrixNormal);

					checkCUDAError("Node hierarchy transformation");

					// at the end of the for loop of primitive
					// push dev pointers to map
					primitiveVector.push_back(PrimitiveDevBufPointers(
						primitive.mode,
						primitiveType,
						numPrimitives,
						numIndices,
						numVertices,

						dev_indices,
						dev_position,
						dev_normal,
						dev_texcoord0,

						dev_diffuseTex,
						diffuseTexWidth,
						diffuseTexHeight,
						diffuseTexComponent,

						dev_vertexOut	//VertexOut
					));

					totalNumPrimitives += numPrimitives;

				} // for each primitive

			} // for each mesh

		} // for each node

	}
	

	// 3. Malloc for dev_primitives
	{
		cudaMalloc(&dev_primitives, totalNumPrimitives * sizeof(Primitive));
		cudaMalloc(&dev_flag, totalNumPrimitives * sizeof(bool));
	}
	

	// Finally, cudaFree raw dev_bufferViews
	{

		std::map<std::string, BufferByte*>::const_iterator it(bufferViewDevPointers.begin());
		std::map<std::string, BufferByte*>::const_iterator itEnd(bufferViewDevPointers.end());
			
			//bufferViewDevPointers

		for (; it != itEnd; it++) {
			cudaFree(it->second);
		}

		checkCUDAError("Free BufferView Device Mem");
	}


}



__global__ 
void _vertexTransformAndAssembly(
	int numVertices, 
	PrimitiveDevBufPointers primitive, 
	glm::mat4 MVP, glm::mat4 MV, glm::mat3 MV_normal, 
	int width, int height) {



	// vertex id
	int vid = (blockIdx.x * blockDim.x) + threadIdx.x;
	if (vid < numVertices) {
		//printf("%d %d\n", vid, numVertices);
		// TODO: Apply vertex transformation here
		// Multiply the MVP matrix for each vertex position, this will transform everything into clipping space
		// Then divide the pos by its w element to transform into NDC space
		// Finally transform x and y to viewport space
		
		primitive.dev_verticesOut[vid].pos = MVP * glm::vec4(primitive.dev_position[vid], 1.0f);
		primitive.dev_verticesOut[vid].pos /= primitive.dev_verticesOut[vid].pos[3];
		//primitive.dev_verticesOut[vid].pos[0] = -primitive.dev_verticesOut[vid].pos[0];
		//primitive.dev_verticesOut[vid].pos[1] = -primitive.dev_verticesOut[vid].pos[1];
		primitive.dev_verticesOut[vid].eyePos = glm::vec3(MV * glm::vec4(primitive.dev_position[vid], 1.0f));
		primitive.dev_verticesOut[vid].eyeNor = glm::normalize(glm::vec3(MV_normal * primitive.dev_normal[vid]));
		primitive.dev_verticesOut[vid].dev_diffuseTex = primitive.dev_diffuseTex;
		primitive.dev_verticesOut[vid].diffuseTexHeight = primitive.diffuseTexHeight;
		primitive.dev_verticesOut[vid].diffuseTexWidth = primitive.diffuseTexWidth;
		primitive.dev_verticesOut[vid].diffuseTexComponent = primitive.diffuseTexComponent;
		//printf("vertex:%d:%f %f %f\n\n", vid, primitive.dev_verticesOut[vid].pos[0],  primitive.dev_verticesOut[vid].pos[1], primitive.dev_verticesOut[vid].pos[2]);
		//printf("normal:%d:%f %f %f\n\n", vid, primitive.dev_verticesOut[vid].eyeNor[0],  primitive.dev_verticesOut[vid].eyeNor[1], primitive.dev_verticesOut[vid].eyeNor[2]);
		//printf("vertex:%d:%f %f %f\n\n", vid, primitive.dev_position[vid][0],  primitive.dev_position[vid][1], primitive.dev_position[vid][2]);
		if (primitive.dev_texcoord0 != NULL)
			primitive.dev_verticesOut[vid].texcoord0 = primitive.dev_texcoord0[vid];
		else;
		//printf("%f %f\n", primitive.dev_verticesOut[vid].texcoord0[0], primitive.dev_verticesOut[vid].texcoord0[1]);
		//primitive.dev_verticesOut[vid].col = glm::vec3(1.0f, 1.0f, 1.0f);
		//primitive.dev_verticesOut[vid].col = c[vid / 3 % 3];
			//printf("NULL TEX\n");
		// TODO: Apply vertex assembly here
		// Assemble all attribute arraies into the primitive array
		
	}
}



static int curPrimitiveBeginId = 0;

__global__ 
void _primitiveAssembly(int numIndices, int curPrimitiveBeginId, Primitive* dev_primitives, PrimitiveDevBufPointers primitive) {
		glm::vec3 c[3];
	c[0] = glm::vec3(1.0f, 0.0f, 0.0f);
	c[1] = glm::vec3(0.0f, 1.0f, 0.0f);
	c[2] = glm::vec3(0.0f, 0.0f, 1.0f);
	// index id
	int iid = (blockIdx.x * blockDim.x) + threadIdx.x;
	if (iid < numIndices) {

		// TODO: uncomment the following code for a start
		// This is primitive assembly for triangles
		int pid;	// id for cur primitives vector
		//pid = iid / (int)primitive.primitiveType;
		//dev_primitives[pid + curPrimitiveBeginId].v[iid % (int)primitive.primitiveType] = primitive.dev_verticesOut[primitive.dev_indices[iid]];
		pid = iid / 3;
		dev_primitives[pid + curPrimitiveBeginId].v[iid % 3] = primitive.dev_verticesOut[primitive.dev_indices[iid]];
		//dev_primitives[pid + curPrimitiveBeginId].v[iid % 3].col = c[iid % 3];
		dev_primitives[pid + curPrimitiveBeginId].v[iid % 3].col = glm::vec3(1.0f, 1.0f, 1.0f);
		//printf("%d\n", pid + curPrimitiveBeginId);
		// TODO: other primitive types (point, line)
	}
	
}

__global__ void _backFaceCulling(int numIndices, Primitive* primitives, bool *flag)
{
	int pid = (blockIdx.x * blockDim.x) + threadIdx.x;
	Primitive cachePrimitive = primitives[pid];
	if (pid < numIndices)
	{
		glm::vec3 v0 = cachePrimitive.v[1].eyePos - cachePrimitive.v[0].eyePos;
		glm::vec3 v1 = cachePrimitive.v[2].eyePos - cachePrimitive.v[0].eyePos;
		glm::vec3 temp = glm::cross(v0, v1);
		if (temp.z < 0.0f)
			flag[pid] = false;
		else
			flag[pid] = true;
	}

}

void _primitivesCompress(int &numIndices, Primitive* primitives, bool *flag)
{
	thrust::device_ptr<bool> dev_ptrFlag(flag);
	thrust::device_ptr<Primitive> dev_primitives(primitives);
	thrust::remove_if(dev_primitives, dev_primitives + numIndices, dev_ptrFlag, thrust::logical_not<bool>());
	numIndices = thrust::count_if(dev_ptrFlag, dev_ptrFlag + numIndices, thrust::identity<bool>());

	//thrust::device_ptr<bool> dev_ptrFlag(flag);
	//thrust::device_ptr<PathSegment> dev_ptrPaths(paths);
	//thrust::remove_if(dev_ptrPaths, dev_ptrPaths + num_paths, dev_ptrFlag, thrust::logical_not<bool>());
	//num_paths = thrust::count_if(dev_ptrFlag, dev_ptrFlag + num_paths, thrust::identity<bool>());
}

__device__ float triangleArea(glm::vec4 v1, glm::vec4 v2)
{
	// dim2 cross product
	v1[2] = v2[2] = 0.0f;
	return glm::length(glm::cross(glm::vec3(v1), glm::vec3(v2))) * 0.5f;
}

__device__ float tArea(float &x1, float &y1, float &x2, float &y2)
{
	// dim2 cross product
	return fabs(x1 * y2 - x2 * y1) * 0.5f;
}
__device__ void print(glm::vec4 v)
{
	printf("%f %f %f %f\n", v[0], v[1], v[2], v[3]);
}

__device__ void clamp(int &i, int a, int b)
{
	if (i < a) i = a;
	else if (i > b) i = b;
}
__device__ void clamp(float &i, float a, float b)
{
	if (i < a) i = a;
	else if (i > b) i = b;
}
__global__ void rasterizer(Fragment *fragment, int *depth, Primitive *primitive, int numPrimitives, int width, int height, int *mutex)
{
	//printf("RARAR\n");
	int pid = (blockIdx.x * blockDim.x) + threadIdx.x;
	//printf("%d\n", numPrimitives);
	if (pid < numPrimitives) {
		//printf("p0:%d:%f %f %f\np1:%d:%f %f %f\np2:%d:%f %f %f\n\n", pid, primitive[pid].v[0].pos[0],  primitive[pid].v[0].pos[1], primitive[pid].v[0].pos[2],
		//	pid, primitive[pid].v[1].pos[0],  primitive[pid].v[1].pos[1], primitive[pid].v[1].pos[2],
		//	pid, primitive[pid].v[2].pos[0],  primitive[pid].v[2].pos[1], primitive[pid].v[2].pos[2]);
		//printf("p0:%d:%f %f %f\np1:%d:%f %f %f\np2:%d:%f %f %f\n\n", pid, primitive[pid].v[0].eyeNor[0],  primitive[pid].v[0].eyeNor[1], primitive[pid].v[0].eyeNor[2],
		//	pid, primitive[pid].v[1].eyeNor[0],  primitive[pid].v[1].eyeNor[1], primitive[pid].v[1].eyeNor[2],
		//	pid, primitive[pid].v[2].eyeNor[0],  primitive[pid].v[2].eyeNor[1], primitive[pid].v[2].eyeNor[2]);
		Primitive cachePrimitive = primitive[pid];
		float p0x = cachePrimitive.v[0].pos[0];
		float p0y = cachePrimitive.v[0].pos[1];
		float p1x = cachePrimitive.v[1].pos[0];
		float p1y = cachePrimitive.v[1].pos[1];
		float p2x = cachePrimitive.v[2].pos[0];
		float p2y = cachePrimitive.v[2].pos[1];

		float x1 = p1x - p0x;
		float y1 = p1y - p0y;
		float x2 = p2x - p0x;
		float y2 = p2y - p0y;
		
		float triArea = tArea(x1, y1, x2, y2);
		//printf("t:%f\n", triArea);

		float minx = 2.0f;
		float maxx = -2.0f;
		float miny = 2.0f;
		float maxy = -2.0f;
		
		minx = min(min(p0x, p1x), p2x);
		maxx = max(max(p0x, p1x), p2x);
		miny = min(min(p0y, p1y), p2y);
		maxy = max(max(p0y, p1y), p2y);

		//minx = min(min(cachePrimitive.v[0].pos[0], cachePrimitive.v[1].pos[0]), cachePrimitive.v[2].pos[0]);
		//maxx = max(max(cachePrimitive.v[0].pos[0], cachePrimitive.v[1].pos[0]), cachePrimitive.v[2].pos[0]);
		//miny = min(min(cachePrimitive.v[0].pos[1], cachePrimitive.v[1].pos[1]), cachePrimitive.v[2].pos[1]);
		//maxy = max(max(cachePrimitive.v[0].pos[1], cachePrimitive.v[1].pos[1]), cachePrimitive.v[2].pos[1]);

		int iMaxx = (-minx + 1.0f) * 0.5f * width;
		int iMinx = (-maxx + 1.0f) * 0.5f * width;
		int iMaxy = (-miny + 1.0f) * 0.5f * height;
		int iMiny = (-maxy + 1.0f) * 0.5f * height;
		// sometimes out of screen
		clamp(iMaxx, 0, width - 1);
		clamp(iMinx, 0, width - 1);
		clamp(iMaxy, 0, height - 1);
		clamp(iMiny, 0, height - 1);

		//printf("%d %d %d %d\n", iMinx, iMaxx, iMiny, iMaxy);
		//int xx0 = (-primitive[pid].v[0].pos[0] + 1) / 2 * width;
		//int yy0 = (-primitive[pid].v[0].pos[1] + 1) / 2 * height;
		////printf("%d %d\n", xx0, yy0);
		//int index = xx0 + yy0 * width;
		//fragment[index].color = glm::vec3(1.0f, 0.0f, 0.0f);
		//int xx1 = (-primitive[pid].v[1].pos[0] + 1) / 2 * width;
		//int yy1 = (-primitive[pid].v[1].pos[1] + 1) / 2 * height;
		//index = xx1 + yy1 * width;
		//fragment[index].color = glm::vec3(1.0f, 0.0f, 0.0f);
		//int xx2 = (-primitive[pid].v[2].pos[0] + 1) / 2 * width;
		//int yy2 = (-primitive[pid].v[2].pos[1] + 1) / 2 * height;
		//index = xx2 + yy2 * width;
		//fragment[index].color = glm::vec3(1.0f, 0.0f, 0.0f);
		float currentPt[2];
		float s0, s1, s2;
		double fDepth;
		float t0, t1, t2;
		for (int j = iMiny; j <= iMaxy; j++)
		//int j = 20;
		{
			//for (int i = 0; i < 800; i++){}
			//for (int i = iMinx; i <= iMaxx; i++){}
			//int i = 20;
			for (int i = iMinx; i <= iMaxx; i++)
			//int i = 390, j = 390;
			{
				int index = i + j * width;
				//fragment[index].color = glm::vec3(1.0f, 0.0f, 0.0f);
				currentPt[0] = 1 - (float)i / width * 2;
				currentPt[1] = 1 - (float)j / height * 2;
				x1 = currentPt[0] - p1x;
				y1 = currentPt[1] - p1y;
				x2 = currentPt[0] - p2x;
				y2 = currentPt[1] - p2y;
				//printf("x1:%f p1x:%f y1:%f x2:%f y2:%f\n", x1, p1x, y1, x2, y2);
				s0 = tArea(x1, y1, x2, y2);
				x1 = currentPt[0] - p0x;
				y1 = currentPt[1] - p0y;
				x2 = currentPt[0] - p2x;
				y2 = currentPt[1] - p2y;
				s1 = tArea(x1, y1, x2, y2);
				x1 = currentPt[0] - p0x;
				y1 = currentPt[1] - p0y;
				x2 = currentPt[0] - p1x;
				y2 = currentPt[1] - p1y;
				s2 = tArea(x1, y1, x2, y2);
				//print(v1);
				//print(v2);
				
				t0 = s0 / triArea;
				
				
				t1 = s1 / triArea;

				//t2 = s2 / (triArea * cachePrimitive.v[2].pos[2]);
				if (triArea < EPSILON)
					t0 = t1 = 0.0f;
				t2 = 1.0f - t1 - t0;

				//if (t0 < 0)
				//	printf("t0:%f %f %f %f\n", s0, triArea, cachePrimitive.v[0].pos[2], (triArea * cachePrimitive.v[0].pos[2]));
				//if (t1 < 0)
				//	printf("t1:%f %f %f %f\n", s1, triArea, cachePrimitive.v[1].pos[2], (triArea * cachePrimitive.v[1].pos[2]));
				//if (t0 > 1 && t2 < 0)
				//	printf("t0:%f %f t0:%f t1:%f t2:%f\n", s0, triArea, t0, t1, t2);


				// new
				// why 
				//glm::vec3 triangle[3] = { glm::vec3(cachePrimitive.v[0].pos), glm::vec3(cachePrimitive.v[1].pos), glm::vec3(cachePrimitive.v[2].pos) };
				//glm::vec3 baryCoords = calculateBarycentricCoordinate(triangle, glm::vec2(currentPt[0], currentPt[1]));
				//float newDepth = glm::dot(baryCoords, glm::vec3(cachePrimitive.v[0].pos.z, cachePrimitive.v[1].pos.z, cachePrimitive.v[2].pos.z));
				glm::vec3 triangle[3] = { glm::vec3(primitive[pid].v[0].pos), glm::vec3(primitive[pid].v[1].pos), glm::vec3(primitive[pid].v[2].pos) };

				 //   AABB boundingBox = getAABBForTriangle(triangle);
					//printf("aabb:%f\n", boundingBox.min.x);
    //int minxpix = clamp(0, boundingBox.min.x, width - 1);
    //int minypix = clamp(0, boundingBox.min.y, height - 1);
    //int maxxpix = clamp(0, boundingBox.max.x, width - 1);
    //int maxypix = clamp(0, boundingBox.max.y, height - 1); 
				glm::vec3 baryCoords = calculateBarycentricCoordinate(triangle, glm::vec2(currentPt[0], currentPt[1]));
				float newDepth = glm::dot(baryCoords, glm::vec3(primitive[pid].v[0].pos[2], primitive[pid].v[1].pos[2], primitive[pid].v[2].pos[2]));
				float testDepth = baryCoords[0] * primitive[pid].v[0].pos[2] + baryCoords[1] * primitive[pid].v[1].pos[2] + baryCoords[2] * primitive[pid].v[2].pos[2];
				int iDepth = newDepth * SCALE;
				//printf("%f %f\n", newDepth, fDepth);
				glm::vec3 ttt[3] = {glm::vec3(cachePrimitive.v[0].pos), glm::vec3(cachePrimitive.v[1].pos), glm::vec3(cachePrimitive.v[2].pos)};

				if (newDepth < 0 || newDepth > 1.0f)
					continue;
				//printf("area:%f %f\n", triArea, calculateSignedArea(ttt));
				//if (newDepth < 0)
				//	printf("%f %f\ncurrent:%f %f\np0:%f %f %f\np1:%f %f %f\np2:%f %f %f\nbary: %f %f %f\ncom1:%f\ncom2:%f\ncom3:%f\n\n", newDepth, testDepth,
				//	currentPt[0], currentPt[1],
				//	primitive[pid].v[0].pos[0], primitive[pid].v[0].pos[1], primitive[pid].v[0].pos[2],
				//	primitive[pid].v[1].pos[0], primitive[pid].v[1].pos[1], primitive[pid].v[1].pos[2],
				//	primitive[pid].v[2].pos[0], primitive[pid].v[2].pos[1], primitive[pid].v[2].pos[2],
				//	baryCoords[0], baryCoords[1], baryCoords[2],
				//	baryCoords[0] * primitive[pid].v[0].pos[2], baryCoords[1] * primitive[pid].v[1].pos[2], baryCoords[2] * primitive[pid].v[2].pos[2]
				//);
				//printf("d:%f %d\n", newDepth, iDepth);
				//clamp(iDepth, -INT_MAX, INT_MAX);
				//clamp(iDepth, 0, INT_MAX);
				//if (newDepth > 1.0f || newDepth <0.0f)
				//	continue;
				// new

				//printf("currentPT:%f %f s:%f %f %f %f area:%f\n", currentPt[0], currentPt[1], s0, s1, s2, s0 + s1 + s2, triArea);
				if (s0 + s1 + s2 <= triArea + 0.00001f)
				{
					//printf("t:%f %f %f\n", t0, t1, t2);
					//printf("currentPT:%f %f s:%f %f %f %f area:%f\n", currentPt[0], currentPt[1], s0, s1, s2, s0 + s1 + s2, triArea);
					//printf("IN\n");
					//if (t0 < 0 || t1 < 0 || t2 < 0)
					//	printf("bary:%f %f %f\n\n", t0, t1, t2);
					//fDepth = t0 * primitive[pid].v[0].pos[2] + t1 * primitive[pid].v[1].pos[2] + t2 * primitive[pid].v[2].pos[2];
				t0 /=  cachePrimitive.v[0].eyePos[2];
				t1 /=  cachePrimitive.v[1].eyePos[2];
				t2 /=  cachePrimitive.v[2].eyePos[2];
					fDepth = 1 / (t0 + t1 + t2);
					//float ttDepth = (float)fDepth * (t0 * cachePrimitive.v[0].col + t1 * cachePrimitive.v[1].col + t2 * cachePrimitive.v[2].col);
					//printf("%f %f\n", newDepth, fDepth);
					//printf("bary:%f %f %f\nbary2:%f %f %f\n\n", baryCoords[0], baryCoords[1], baryCoords[2], s0/triArea, s1/triArea, s2/triArea);
				//printf("depth:%f\n", fDepth);
					//printf("s0:%f s1:%f s2:%f total:%f %f\n", s0, s1, s2, s0 + s1 + s2, triArea);
					{
						//printf("index:%d\n", index);
						//fragment[index].color = glm::vec3(1.0f, 0.0f, 0.0f);
						//if (atomicCAS(&mutex[index], 0, 1) == 0)
						//{
						//	if (fDepth < depth[index])
						//	{
						//		//printf("HERE");
						//		//printf("%d\n", index);
						//	fragment[index].color = fDepth * (t0 * cachePrimitive.v[0].col + t1 * cachePrimitive.v[1].col + t2 * cachePrimitive.v[2].col);
						//	depth[index] = fDepth;
						//	}
						//	mutex[index] = 0;
						//	
						//	//if (index == 334800)
						//	//	printf("ONE %d\n", mutex[index]);
						//}
						bool isSet = false;
						do
						{
							isSet = (atomicCAS(&mutex[index], 0, 1) == 0);
							if (isSet)
							{
								//if (fDepth < depth[index])
								//if (iDepth < depth[index])
								if (newDepth < fragment[index].z)
								{
									fragment[index].z = newDepth;
									fragment[index].hasColor = true;
									//printf("HERE");
									//printf("%d\n", index);
									//fragment[index].color = glm::vec3(-newDepth, -newDepth, -newDepth);
									fragment[index].color = (float)fDepth * (t0 * cachePrimitive.v[0].col + t1 * cachePrimitive.v[1].col + t2 * cachePrimitive.v[2].col);
//printf("p0:%d:%f %f %f\np1:%d:%f %f %f\np2:%d:%f %f %f\n\n", pid, primitive[pid].v[0].col[0],  primitive[pid].v[0].col[1], primitive[pid].v[0].col[2],
//	pid, primitive[pid].v[1].col[0],  primitive[pid].v[1].col[1], primitive[pid].v[1].col[2],
//	pid, primitive[pid].v[2].col[0],  primitive[pid].v[2].col[1], primitive[pid].v[2].col[2]);
//									fragment[index].color = glm::dot(baryCoords, glm::vec3(cachePrimitive.v[0].pos.z, cachePrimitive.v[1].pos.z, cachePrimitive.v[2].pos.z));
									fragment[index].eyePos[0] = (float)fDepth * (t0 * cachePrimitive.v[0].pos[0] + t1 * cachePrimitive.v[1].pos[0] + t2 * cachePrimitive.v[2].pos[0]);
									fragment[index].eyePos[1] = (float)fDepth * (t0 * cachePrimitive.v[0].pos[1] + t1 * cachePrimitive.v[1].pos[1] + t2 * cachePrimitive.v[2].pos[1]);
									fragment[index].eyePos[2] = fDepth;
									fragment[index].eyeNor = (float)fDepth * (t0 * cachePrimitive.v[0].eyeNor + t1 * cachePrimitive.v[1].eyeNor + t2 * cachePrimitive.v[2].eyeNor);
									fragment[index].texcoord0 = (float)fDepth * (t0 * cachePrimitive.v[0].texcoord0 + t1 * cachePrimitive.v[1].texcoord0 + t2 * cachePrimitive.v[2].texcoord0);
									//fragment[index].texcoord0 = baryCoords[0] * cachePrimitive.v[0].texcoord0 + baryCoords[1] * cachePrimitive.v[1].texcoord0 + baryCoords[2] * cachePrimitive.v[2].texcoord0;
									clamp(fragment[index].texcoord0[0], 0.0f, 1.0f);
									clamp(fragment[index].texcoord0[1], 0.0f, 1.0f);
									//fragment[index].color = glm::vec3(fragment[index].texcoord0.x, fragment[index].texcoord0.y, 0.0f);
									//fragment[index].texcoord0 = baryCoords[0] * cachePrimitive.v[0].texcoord0 + baryCoords[1] * cachePrimitive.v[1].texcoord0 + baryCoords[2] * cachePrimitive.v[2].texcoord0;
									//if (fragment[index].texcoord0[0]<0 || fragment[index].texcoord0[0]>1 || fragment[index].texcoord0[1]< 0 || fragment[index].texcoord0[1]>1)
									//printf("bary:%f %f %f\n%f %f\n\n", baryCoords[0], baryCoords[1], baryCoords[2],
									//fragment[index].texcoord0[0], fragment[index].texcoord0[1]);
									//if (t0 < 0 || t1 < 0 || t2 < 0)
									//	printf("bary:%f %f %f\n%f %f\n\n", t0, t1, t2,
									//fragment[index].texcoord0[0], fragment[index].texcoord0[1]);
									if (cachePrimitive.v[0].dev_diffuseTex != NULL)
									{
										fragment[index].dev_diffuseTex = cachePrimitive.v[0].dev_diffuseTex;
										fragment[index].diffuseTexHeight = cachePrimitive.v[0].diffuseTexHeight;
										fragment[index].diffuseTexWidth = cachePrimitive.v[0].diffuseTexWidth;
										fragment[index].diffuseTexComponent = cachePrimitive.v[0].diffuseTexComponent;
									}
//printf("%f %f %f\n\n", fragment[index].eyeNor[0], fragment[index].eyeNor[1], fragment[index].eyeNor[2]);
									depth[index] = iDepth;
								}
								//mutex[index] = 0;
								
								//if (index == 334800)
								//	printf("ONE %d\n", mutex[index]);
							}
							if (isSet)
								mutex[index] = 0;

						} while (!isSet);
						//fragment[index].eyeNor = 
						//atomicMin(&depth[index], fDepth);
					}
				}
			}

		}
	}

}
//float time_elapsed = 0.0f;
//cudaEvent_t start,stop;
//cudaEventCreate(&start);
//cudaEventCreate(&stop);
//cudaEventRecord( start,0);
//
//cudaEventRecord( stop,0);
//cudaEventSynchronize(start);
//cudaEventSynchronize(stop);
//cudaEventElapsedTime(&time_elapsed,start,stop);
/**
 * Perform rasterization.
 */
float stime[100];
cudaEvent_t start,stop;
float time_elapsed;
void rasterize(uchar4 *pbo, const glm::mat4 & MVP, const glm::mat4 & MV, const glm::mat3 MV_normal, int counter) {
	//counter++;
	FILE *fp = fopen("time.txt", "a+");
    int sideLength2d = 8;
    dim3 blockSize2d(sideLength2d, sideLength2d);
    dim3 blockCount2d((width  - 1) / blockSize2d.x + 1,
		(height - 1) / blockSize2d.y + 1);

	// Execute your rasterization pipeline here
	// (See README for rasterization pipeline outline.)

	// Vertex Process & primitive assembly
	dim3 numThreadsPerBlock(128);
	{
		curPrimitiveBeginId = 0;
		

		auto it = mesh2PrimitivesMap.begin();
		auto itEnd = mesh2PrimitivesMap.end();
		
		for (; it != itEnd; ++it) {
			auto p = (it->second).begin();	// each primitive
			auto pEnd = (it->second).end();
			for (; p != pEnd; ++p)
		//PrimitiveDevBufPointers *p;
		//p = new PrimitiveDevBufPointers(s
			{
				dim3 numBlocksForVertices((p->numVertices + numThreadsPerBlock.x - 1) / numThreadsPerBlock.x);
				dim3 numBlocksForIndices((p->numIndices + numThreadsPerBlock.x - 1) / numThreadsPerBlock.x);
				//printf("stop1\n");
				//cudaDeviceSynchronize();
time_elapsed = 0.0f;
cudaEventCreate(&start);
cudaEventCreate(&stop);
cudaEventRecord(start,0);
				_vertexTransformAndAssembly << < numBlocksForVertices, numThreadsPerBlock >> >(p->numVertices, *p, MVP, MV, MV_normal, width, height);
cudaEventRecord( stop,0);
cudaEventSynchronize(start);
cudaEventSynchronize(stop);
cudaEventElapsedTime(&time_elapsed,start,stop);
stime[0] += time_elapsed;

				checkCUDAError("Vertex Processing");
				//printf("stop2\n");
				//cudaDeviceSynchronize();
				//printf("stop3\n");
time_elapsed = 0.0f;
cudaEventCreate(&start);
cudaEventCreate(&stop);
cudaEventRecord(start,0);
				_primitiveAssembly << < numBlocksForIndices, numThreadsPerBlock >> >
					(p->numIndices, 
					curPrimitiveBeginId, 
					dev_primitives, 
					*p);
cudaEventRecord(stop,0);
cudaEventSynchronize(start);
cudaEventSynchronize(stop);
cudaEventElapsedTime(&time_elapsed,start,stop);
stime[1] += time_elapsed;
				//printf("stop4\n");
				checkCUDAError("Primitive Assembly");
				//cudaDeviceSynchronize();
				//printf("stop5\n");
				curPrimitiveBeginId += p->numPrimitives;
			}
		}
		

		checkCUDAError("Vertex Processing and Primitive Assembly");
	}
	dim3 numBlocksForPrimitives((curPrimitiveBeginId + numThreadsPerBlock.x - 1) / numThreadsPerBlock.x);
time_elapsed = 0.0f;
cudaEventCreate(&start);
cudaEventCreate(&stop);
cudaEventRecord(start,0);
	//_backFaceCulling<< < numBlocksForPrimitives, numThreadsPerBlock >> >(curPrimitiveBeginId, dev_primitives, dev_flag);
	//_primitivesCompress(curPrimitiveBeginId, dev_primitives, dev_flag);
cudaEventRecord(stop,0);
cudaEventSynchronize(start);
cudaEventSynchronize(stop);
cudaEventElapsedTime(&time_elapsed,start,stop);
stime[2] += time_elapsed;

	cudaMemset(dev_fragmentBuffer, 0, width * height * sizeof(Fragment));
	initDepth << <blockCount2d, blockSize2d >> >(width, height, dev_depth, dev_fragmentBuffer);
	//printf("id:%d total:%d\n", curPrimitiveBeginId, totalNumPrimitives);	
	// TODO: rasterize
	
	//printf("%d\n", (curPrimitiveBeginId + numThreadsPerBlock.x - 1) / numThreadsPerBlock.x);

	cudaMemset(dev_mutex, 0, width * height * sizeof(int));
time_elapsed = 0.0f;
cudaEventCreate(&start);
cudaEventCreate(&stop);
cudaEventRecord(start,0);
	rasterizer<<<numBlocksForPrimitives, numThreadsPerBlock>>>(dev_fragmentBuffer, dev_depth, dev_primitives, curPrimitiveBeginId, width, height, dev_mutex);
cudaEventRecord(stop,0);
cudaEventSynchronize(start);
cudaEventSynchronize(stop);
cudaEventElapsedTime(&time_elapsed,start,stop);
stime[3] += time_elapsed;
	
    // Copy depthbuffer colors into framebuffer
time_elapsed = 0.0f;
cudaEventCreate(&start);
cudaEventCreate(&stop);
cudaEventRecord(start,0);
	render << <blockCount2d, blockSize2d >> >(width, height, dev_fragmentBuffer, dev_framebuffer);
cudaEventRecord(stop,0);
cudaEventSynchronize(start);
cudaEventSynchronize(stop);
cudaEventElapsedTime(&time_elapsed,start,stop);
stime[4] += time_elapsed;

	checkCUDAError("fragment shader");
    // Copy framebuffer into OpenGL buffer for OpenGL previewing
    sendImageToPBO<<<blockCount2d, blockSize2d>>>(pbo, width, height, dev_framebuffer);
    checkCUDAError("copy render result to pbo");

if (counter == 59)
{
	for (int i = 0; i < 5; i++)
		fprintf(fp, "%f	", stime[i]);
	fprintf(fp, "\n");
	fclose(fp);
	printf("DONE\n");
}

}

/**
 * Called once at the end of the program to free CUDA memory.
 */
void rasterizeFree() {

    // deconstruct primitives attribute/indices device buffer

	auto it(mesh2PrimitivesMap.begin());
	auto itEnd(mesh2PrimitivesMap.end());
	for (; it != itEnd; ++it) {
		for (auto p = it->second.begin(); p != it->second.end(); ++p) {
			cudaFree(p->dev_indices);
			cudaFree(p->dev_position);
			cudaFree(p->dev_normal);
			cudaFree(p->dev_texcoord0);
			cudaFree(p->dev_diffuseTex);

			cudaFree(p->dev_verticesOut);

			
			//TODO: release other attributes and materials
		}
	}

	////////////

    cudaFree(dev_primitives);
    dev_primitives = NULL;

	cudaFree(dev_fragmentBuffer);
	dev_fragmentBuffer = NULL;

    cudaFree(dev_framebuffer);
    dev_framebuffer = NULL;

	cudaFree(dev_depth);
	dev_depth = NULL;

	cudaFree(dev_mutex);
	dev_mutex = NULL;

	cudaFree(dev_flag);
	dev_flag = NULL;
    checkCUDAError("rasterize Free");
}

//__global__ void _AdvanceParticle(PrimitiveDevBufPointers *p, int toIndex)
//{
//
//}

//void paticleSystem(uchar4 *pbo, const glm::mat4 &MVP)
//{
//	int sideLength2d = 8;
//    dim3 blockSize2d(sideLength2d, sideLength2d);
//    dim3 blockCount2d((width  - 1) / blockSize2d.x + 1, (height - 1) / blockSize2d.y + 1);
//
//	dim3 numThreadsPerBlock(128);
//	PrimitiveDevBufPointers *p[2];
//	p[0] = new PrimitiveDevBufPointers();
//	p[1] = new PrimitiveDevBufPointers();
//
//	_AdvanceParticle();
//	
//}

