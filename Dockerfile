FROM python:3.7

RUN apt update \
	&& apt install -y --no-install-recommends \
	build-essential \
	graphviz \
	python-opengl \
	tk-dev \
	x11-utils \
	xvfb \
	&& apt clean \
	&& rm -rf /var/lib/apt/lists/*

RUN pip3 install -U pip setuptools \
	&& pip3 install -U \
	coverage \
	cython \
	gym[box2d] \
	matplotlib \
	numpy \
	pyvirtualdisplay \
	sphinx \
	sphinx-automodapi \
	sphinx_rtd_theme \
	twine \
	unittest-xml-reporting \
	wheel

CMD ["/bin/bash"]
