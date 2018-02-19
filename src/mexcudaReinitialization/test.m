%
%mexcuda mexcudaReinitialization.cu Reinitialization.cu

addpath(genpath('..'))

% test mexcudaReinitialization scheme

	% 
		a = 210;
		b = 210;
		c = 114;

		xv = linspace(-250,250,64);
		yv = xv;
		%zv = xv(abs(xv)<150);
		zv = xv;

		%[x, y, z] = meshgrid(xv, yv, zv); % simulation domain in nm
		dx = xv(2)-xv(1);
		dy = yv(2)-yv(1);
		dz = zv(2)-zv(1);

		F = sqrt(x.^2/a^2 + y.^2/b^2 + z.^2/c^2) - 1;

%

% 
xv = linspace(-5,5,64);
yv = xv;
zv = xv;

[x, y, z] = meshgrid(xv,yv,zv);

fun = @(x,y,z) (0.1+(x-3.5).^2+(sqrt(y.^2+z.^2)-2).^2) .* (sqrt(x.^2/4+(z.^2+y.^2)/9)-1);

F = fun(x,y,z);


for i=1:1
	new_F = mexcudaReinitialization(F,[dx, dy, dz]);
end

