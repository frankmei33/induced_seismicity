# =================================================================================================
# CLEAN DATA / SET UP WORKING ENVIRONMENT

# Author: Michael Jetsupphasuk
# Last Updated: 31 October, 2017

# This file creates the relevant data frames and Spatial objects for further analysis. 

# California Boundaries:
#     - Loads boundaries from map_data from `ggplot2`, `maps` packages
#     - Creates data in following formats:
#         + data frame
#         + spatial points data frame (`sp`)
#         + spatial polygon (`sp`)

# Grid:
#     - Creates a 0.2 x 0.2 degree long/lat grid
#     - Creates a spatial grid (`sp`)

# Earthquakes:
#     - See scrape/get_eq.R for query information
#     - Filter earthquakes for only ones in california (exclude offshore)
#     - Earthquakes mapped to grid (from above)
#     - Creates a data frame

# Wells:
#     - See scrape/get_inj.R for injection information
#     - Links various data frames together to gather all relevant information
#     - Wells mapped to grid (from above)
#     - Creates data in following formats:
#         + long data frame (each row a combination of well, injection date)
#         + wide data frame (each row is a unique well)
#         + spatial points data frame (wide data)

# =================================================================================================

# LOAD LIBRARIES ----------------------------------------------------------

library(dplyr)
library(stringr)
library(tidyr)

library(maps)
library(maptools)

library(sp)  # vector data
library(raster)  # raster data
library(rgdal)  # input/output, projections
library(rgeos)  # geometry ops
library(spdep)  # spatial dependence

library(ggmap)
# citation('ggmap')

library(spatstat)


# GLOBAL PARAMETERS -------------------------------------------------------

my_crs = CRS( "+proj=longlat +ellps=WGS84 +datum=WGS84" )


# CALIFORNIA BOUNDARIES ---------------------------------------------------

# get california boundaries
cal = map_data("state") %>% filter(region == 'california')

# convert boundaries to a SpatialPointsDataFrame
cal_points = SpatialPointsDataFrame(coords = cal %>% dplyr::select(long, lat),
                                    data = data.frame(ID = 1:nrow(cal)),
                                    proj4string = CRS( "+proj=longlat +ellps=WGS84 +datum=WGS84" ))

# convert boundaries to a SpatialPolygon
cal_poly = Polygon(cal[ , c("long", "lat")])
cal_polys = Polygons(list(cal_poly), 1)
cal_spolys = SpatialPolygons(list(cal_polys))
proj4string(cal_spolys) = CRS( "+proj=longlat +ellps=WGS84 +datum=WGS84" )


# GRID --------------------------------------------------------------------

# create grid from california points data
grid = makegrid(cal_points, cellsize = 0.2)
grid = SpatialPoints(grid, proj4string = my_crs)
grid = points2grid(grid)
grid_sp = SpatialGrid(grid, proj4string = my_crs)

# grid_sp_df = SpatialGridDataFrame(grid, data.frame(value = 1:length(grid_sp)),
#                                   proj4string = my_crs)
# grid_df = data.frame(grid_sp_df)


# EARTHQUAKES -------------------------------------------------------------

# read in data generated by scrape/get_eq.R
ca_eq = read.csv("rawdata/earthquakes/california/ca_eq_raw25.csv")

# convert longitude/latitude to numeric; add time columns
ca_eq = ca_eq %>%
  mutate(longitude = as.numeric(as.character(longitude)),
         latitude = as.numeric(as.character(latitude)),
         time_year = as.numeric(substr(time, 1, 4)),
         time_dec = floor(time_year/10)*10)

# convert earthquakes data frame to SpatialPoints object
ca_eq_sp = SpatialPoints(ca_eq %>% dplyr::select(longitude, latitude),
                         proj4string = my_crs)

# map earthquakes to california polygon and filter for only in state
which_ca = over(ca_eq_sp, cal_spolys)
which_ca[which_ca == 1] = "california"
ca_eq = ca_eq %>%
          mutate(state = which_ca) %>%
          filter(state == "california")

# map earthquakes spatial points to grid
eq_xy = data.frame(x = ca_eq$longitude,
                   y = ca_eq$latitude,
                   id = "A",
                   stringsAsFactors = F)
coordinates(eq_xy) = ~ x + y 
proj4string(eq_xy) = my_crs
cellIDs = over(eq_xy, grid_sp)
ca_eq$Grid = cellIDs

# colnames(cellIDs) = "Grid"
# ca_eq = bind_cols(ca_eq, cellIDs)


# WELLS -------------------------------------------------------------------

## Read in well locations

# shapefile from ftp://ftp.consrv.ca.gov/pub/oil/GIS/Shapefiles/
well_locs = readOGR(dsn = 'rawdata/wells/california/shapefiles/AllWells',
                   layer = "AllWells_20170316")
            
well_locs = spTransform(well_locs, CRSobj = my_crs)

# we will ignore wells with obviously inaccurate latitude/longitude
# only include columns that might be relevant
well_locs_df = data.frame(well_locs) %>%
                filter(Latitude != 0,
                       Longitude != 0) %>%
                mutate(APINumber = as.numeric(as.character(APINumber))) %>%
                dplyr::select(APINumber, BLMWell, CompDate,
                              ConfWell, coords.x1, coords.x2,
                              County, District, DryHole, Elevation,
                              EPAWell, HydFrac, RedCanFlag,
                              RedrillFt, SpudDate, TotalDepth,
                              WellNumber, WellStatus)

## Read in injection data

# read in data generated by scrape/get_inj.R
inj_wells = readRDS("rawdata/wells/california/raw_injection_wells.rds")

# select only columns that might be relevant
inj_wells = inj_wells %>%
              mutate(APINumber = as.numeric(APINumber)) %>%
              dplyr::select(APINumber, CountyName, DaysInjecting,
                            DistrictNumber, InjectionDate, InjectionStatus,
                            MissingDataCode, PoolCode, PoolName,
                            PoolWellTypeStatus, Steam.WaterInjected.BBL.,
                            SurfaceInjPressure, SystemEntryDate, WellNumber,
                            WellStatus, WellTypeCode, Year)

## Join location and injection data

# data in long format (i.e. each row is a combination of well, injection date)
wells_long = inner_join(inj_wells, well_locs_df, by = c("APINumber")) %>%
                mutate(Year = as.numeric(Year),
                       Steam.WaterInjected.BBL. = as.numeric(Steam.WaterInjected.BBL.),
                       coords.x1 = as.numeric(coords.x1),
                       coords.x2 = as.numeric(coords.x2)) %>%
                rename(WaterInjected = Steam.WaterInjected.BBL.,
                       Longitude = coords.x1,
                       Latitude = coords.x2) %>%
                filter(Year >= 1980,
                       WellTypeCode == "WD",
                       Longitude < -80)

# mapping long wells to grid
wells_long_xy = data.frame(x = wells_long$Longitude,
                           y = wells_long$Latitude,
                           id = "A",
                           stringsAsFactors = F)
coordinates(wells_long_xy) = ~ x + y 
proj4string(wells_long_xy) = my_crs
cellIDs = over(wells_long_xy, grid_sp)
wells_long$Grid = cellIDs

# also create a wide data frame (i.e. each row is a unique well)
wells_wide = wells_long %>%
              # filter(CountyName == 'Kern') %>%
              dplyr::select(APINumber,
                            InjectionDate, 
                            WaterInjected,
                            Longitude,
                            Latitude) %>%
              distinct(APINumber, InjectionDate, .keep_all = T) %>%
              group_by(APINumber) %>%
              spread(key = InjectionDate,
                     value = WaterInjected) %>%
              data.frame()

# mapping wide wells spatial points to grid
wells_wide_xy = data.frame(x = wells_wide$Longitude,
                           y = wells_wide$Latitude,
                           id = "A",
                           stringsAsFactors = F)
coordinates(wells_wide_xy) = ~ x + y 
proj4string(wells_wide_xy) = my_crs
cellIDs = over(wells_wide_xy, grid_sp)
wells_wide$Grid = cellIDs

# convert wide wells to a SpatialPointsDataFrame
wells_wide_sp = SpatialPointsDataFrame(coords = wells_wide %>% 
                                                  dplyr::select(Longitude, Latitude),
                                       data = wells_wide %>% 
                                                dplyr::select(-Longitude, -Latitude),
                                       proj4string = my_crs)



# SAVING ------------------------------------------------------------------

rm(inj_wells)
rm(which_ca)
rm(well_locs)
rm(well_locs_df)
save.image(file = "clean_data.RData")
save.image()
