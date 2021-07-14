#!/bin/bash

## uncomment these lines to re-export basins from GRDC database (250 Mb to download)

# wget ftp://ftp.bafg.de/pub/REFERATE/GRDC/grdc_major_river_basins_shp.zip
# unzip -d shp grdc_major_river_basins_shp.zip
# grdc="shp/grdc_major_river_basins_shp/mrb_basins.shp"
# ogr2ogr -where "RIVER_BASI='INDUS'" shp/INDUS.shp $grdc
# ogr2ogr -where "RIVER_BASI='GANGES'" shp/GANGES.shp $grdc
# ogr2ogr -where "RIVER_BASI='BRAHMAPUTRA'" shp/BRAHMAPUTRA.shp $grdc

# equal area projection centered in HMA region
projEqArea="+proj=aea +lon_0=82.5 +lat_1=29.1666667 +lat_2=41.8333333 +lat_0=35.5 +datum=WGS84 +units=m +no_defs"

# variable loop
for v in "SUBLIM" "SNOWMELT"
do

    # HMASR files were downloaded from NSIDC to this folder
    pin="/media/data/HMA/${v}"

    # rearrange original netcdf files to be GDAL compatible (https://gis.stackexchange.com/a/377498)
    pout=${pin}"transposed/"
    mkdir -p ${pout}
    parallel ncpdq -a Latitude,Longitude {} ${pout}{/} ::: $(ls ${pin}/*.nc)

    # mosaicing all tiles of 1° latitude by 1° longitude into a single virtual raster
    parallel gdalbuildvrt $pout/HMA_SR_D_v01_WY{}_${v}.vrt $pout/*WY{}*nc ::: $(seq 2000 2016)

    # compute statistics by basin 
    for BV in "INDUS" "BRAHMAPUTRA" "GANGES" 
    do
        # regrid to equal area projection before aggregrating (nearest neighbor method to accelerate processing)
        parallel -j1 gdalwarp -multi -wo NUM_THREADS=ALL_CPUS -co COMPRESS=DEFLATE -s_srs EPSG:4326 --config GDALWARP_IGNORE_BAD_CUTLINE YES -r near -t_srs "'"${projEqArea}"'" -crop_to_cutline -cutline shp/$BV.shp $pout/HMA_SR_D_v01_WY{}_${v}.vrt $pout/HMA_SR_D_v01_WY{}_${v}_${BV}.tif ::: $(seq 2000 2016)

        # compute stats from valid pixels (gdalinfo is faster than gdal+numpy, easier than dask+xarray)
        parallel gdalinfo -stats ::: $pout/HMA_SR_D_v01*${v}_${BV}.tif

        # count valid pixels (vpc) in the basin using (here we need python)
        f=$(ls $pout/HMA_SR_D_v01_WY*_${v}_${BV}.tif | head -n1)
        vpc=$(python -c "import gdal; a=gdal.Open('${f}'); print((a.GetRasterBand(1).ReadAsArray()!=-999).sum())")

        # area of a pixel in m2
        pixArea=$(gdalinfo $f | grep "Pixel Size" | cut -d= -f2 | tr "," "*" | tr -d "-" | bc)

        # basin area in km2
        basinArea=$(ogrinfo shp/$BV.shp -al -geom=SUMMARY | grep "AREA_CALC (Real) =" | cut -d= -f2)

        # export data to tables
        mkdir -p tables

        # integrate the daily flux over the valid pixels (e.g. snowmelt was provided in mm/day, hence total is in 0.001*m3/day)
        f=HMA_SR_D_v01_DAYM3_${v}_${BV}.csv
        # first fill a column with the DOY
        for i in $(seq 1 366); do echo $i ; done > tmp0
        # get mean daily value from metadata
        for i in $(seq 2000 2016); do
            gdalinfo $pout/HMA_SR_D_v01_WY${i}_${v}_${BV}.tif | grep "STATISTICS_MEAN" | cut -d= -f2 | awk -v c="$vpc" -v a="$pixArea" '{print $1 * c * a }' > tmp1
            paste -d" " tmp0 tmp1 > tmp2 && mv -f tmp2 tmp0
        done
        # add the years as a header to the table
        echo " "$(seq 2000 2016) | cat - tmp0 > tables/$f

        # export time cumulated specific flux in mm from 1 to 366
        f=HMA_SR_D_v01_MMCUM_${v}_${BV}.csv
        for i in $(seq 1 366); do echo $i ; done > tmp0
        for i in $(seq 2000 2016); do
            gdalinfo $pout/HMA_SR_D_v01_WY${i}_${v}_${BV}.tif | grep "STATISTICS_MEAN" | cut -d= -f2 | awk -v c="$vpc" -v a="$pixArea" -v b="$basinArea" '{print s+=$1 * c * a / b / 1e6}' > tmp1
            paste -d" " tmp0 tmp1 > tmp2 && mv -f tmp2 tmp0
        done
        echo " "$(seq 2000 2016) | cat - tmp0 > tables/$f

    done

done
# remove tmp files
rm -f tmp*
echo "end"
date

# export only annual total
#gdalinfo $f | grep "STATISTICS_MEAN" | cut -d= -f2 | awk -v c="$vpc" -v a="$pixArea" '{ s+=$1 } END {print s * c * a/ 865012e6 }'

#One liner to export zonal stats
#fio cat ../HDR/grdc_major_river_basins_shp/mrb_basins.shp | fio filter "f.properties.RIVER_BASI == 'INDUS' " | rio zonalstats -r WY2000_SNOWMELT.tif --band 1 --prefix "SNOWMELT_" --all-touched | ogrinfo /vsistdin/ -geom=NO -al 