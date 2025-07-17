FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive 

# install python 3.12
RUN apt-get update && \
    apt-get install -y software-properties-common && \
    add-apt-repository ppa:deadsnakes/ppa && \
    apt-get update && \
    apt-get install -y python3.12 python3.12-venv python3.12-dev git build-essential ninja-build wget curl ca-certificates gpg gcc-12 g++-12

# Set python3.12 as the default python3
RUN update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.12 1
RUN update-alternatives --set python3 /usr/bin/python3.12
RUN update-alternatives --install /usr/bin/python python /usr/bin/python3.12 1
RUN update-alternatives --set python /usr/bin/python3.12

# Install a newer cmake
RUN wget -O - https://apt.kitware.com/keys/kitware-archive-latest.asc 2>/dev/null | gpg --dearmor - > /usr/share/keyrings/kitware-archive-keyring.gpg
RUN echo 'deb [signed-by=/usr/share/keyrings/kitware-archive-keyring.gpg] https://apt.kitware.com/ubuntu/ jammy main' | tee /etc/apt/sources.list.d/kitware.list >/dev/null
RUN apt-get update && \
    apt-get install -y kitware-archive-keyring && \
    apt-get install -y cmake

# TT dependencies
RUN apt-get install -y libnuma-dev libhwloc-dev libtinfo-dev libncurses5-dev libncursesw5-dev libboost-all-dev libjemalloc-dev libgoogle-glog-dev libgflags-dev

RUN wget https://download.open-mpi.org/release/open-mpi/v5.0/openmpi-5.0.7.tar.bz2 && \
    tar -xjf openmpi-5.0.7.tar.bz2 && \
    cd openmpi-5.0.7 && \
    ./configure --prefix=/usr/local/mpi  && \
    make -j$(nproc) && \
    make install && \
    ldconfig

# set up environment variables
ENV MPI_HOME=/usr/local/mpi
ENV PATH=$MPI_HOME/bin:$PATH
ENV TT_METAL_HOME=/tt-metal
ENV ARCH_NAME=wormhole_b0
ENV LD_LIBRARY_PATH=/tt-metal/install/lib:$MPI_HOME/lib:$LD_LIBRARY_PATH
ENV PYTHONPATH=/tt-metal:$PYTHONPATH
ENV VLLM_TARGET_PLATFORM=tt
ENV WH_ARCH_YAML=wormhole_b0_80_arch_eth_dispatch.yaml 
ENV MESH_DEVICE=N300

# clone tt-metal
RUN git clone --depth=1 https://github.com/tenstorrent/tt-metal.git /tt-metal && \
    cd /tt-metal && \
    git submodule update --init --recursive && \
    mkdir build && \
    cd build && \
    cmake .. -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/tt-metal/install -DTT_UNITY_BUILD=ON -DCMAKE_C_COMPILER=/usr/bin/gcc-12 -DCMAKE_CXX_COMPILER=/usr/bin/g++-12 -G Ninja && \
    ninja && \
    ninja install
    
# Bootstrap rust (for tt-smi)
RUN curl https://sh.rustup.rs -sSf | sh -s -- -y

# create a virtual environment but comment out the "pip install --force-reinstall pip==21.2.4" line
RUN . "$HOME/.cargo/env" && cd /tt-metal && \
    sed -i 's/pip install --force-reinstall pip==21.2.4/# pip install --force-reinstall pip==21.2.4/' create_venv.sh && \
    bash create_venv.sh


RUN git clone -b dev --depth=1 https://github.com/tenstorrent/vllm.git /vllm && \
    cd /vllm && \
    . /tt-metal/python_env/bin/activate && \
    pip install --upgrade pip && \
    pip install .

RUN . /tt-metal/python_env/bin/activate && \
    pip install numpy==1.26.4 

# Cleanup
RUN apt-get clean && \
    rm -rf /var/lib/apt/lists/* && \
    rm -rf /tt-metal/build && \
    rm -rf /vllm/.git && \
    rm -rf /tt-metal/.git && \
    rm -rf /openmpi-5.0.7.tar.bz2 && \
    rm -rf /openmpi-5.0.7 && \
    rm -rf /root/.cache && \
    rm -rf /tt-metal/.cpmcache && \
    rm -rf /vllm/.deps

# Entry point that automatically activates the venv and spawns an interactive shell
RUN cat <<EOF > /etc/entrypoint.sh
#!/bin/bash
source /tt-metal/python_env/bin/activate

if ! [ -d /dev/tenstorrent ]; then
    echo "Warning: /dev/tenstorrent not found. Ensure the Tenstorrent device is mounted."
fi

if ! [ -d /dev/hugepages-1G ]; then
    echo "Warning: /dev/hugepages-1G not found. Ensure the hugepages are mounted."
fi

cd /vllm
echo "Make sure you set HF_MODEL or LLAMA_DIR before running models."

exec /bin/bash --login
EOF

RUN chmod +x /etc/entrypoint.sh
EXPOSE 8000

# start interactive shell by default inside venv
ENTRYPOINT ["/etc/entrypoint.sh"]